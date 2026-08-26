// license:BSD-3-Clause
// copyright-holders:mame-mcp
//
// session.mjs - owns a MAME child process and the JSON-RPC link to the
// plugins/mcp Lua plugin running inside it.
//
// Responsibilities the emulator should not have:
//   * process lifecycle (spawn, crash detection, shutdown)
//   * keeping MAME's stdout/stderr away from the MCP stdio stream
//   * request/response correlation and timeouts
//   * turning the plugin's push notifications into awaitable events
//     (this is how exec.wait_for_stop works without blocking the emu loop)

import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

const CONNECT_RETRIES = 100;
const CONNECT_DELAY_MS = 100;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class MameSession extends EventEmitter {
  constructor(opts = {}) {
    super();
    this.mameBin = opts.mameBin || process.env.MAME_BINARY || './mametiny';
    this.mameDir = opts.mameDir || process.env.MAME_DIR || process.cwd();
    this.rompath = opts.rompath || process.env.MAME_ROMPATH || 'roms';
    this.artifacts = opts.artifacts ||
      process.env.MAME_MCP_ARTIFACTS || path.join(os.tmpdir(), 'mame-mcp-artifacts');

    this.proc = null;
    this.sock = null;
    this.driver = null;
    this.ready = false;
    this.execState = 'unknown';
    this.lastStop = null;

    this._buf = '';
    this._nextId = 1;
    this._pending = new Map();
    this._log = [];          // MAME stderr/stdout ring buffer
    this._consoleLog = [];   // debugger console lines pushed by the plugin
  }

  // ------------------------------------------------------------------ start

  async start(driver, opts = {}) {
    if (this.proc) throw new Error('session already running; call session.stop first');

    fs.mkdirSync(this.artifacts, { recursive: true });

    // A UNIX socket avoids port collisions when several sessions run at once.
    this.sockPath = path.join(os.tmpdir(), `mame-mcp-${process.pid}-${Date.now()}.sock`);
    try { fs.unlinkSync(this.sockPath); } catch { /* not present */ }

    const args = [
      driver,
      '-video', 'none',
      '-sound', opts.sound === true ? 'sdl' : 'none',
      '-nothrottle',
      '-debug', '-debugger', 'none',
      '-plugin', 'mcp',
      '-rompath', this.rompath,
      '-snapshot_directory', this.artifacts,
      '-nvram_directory', path.join(this.artifacts, 'nvram'),
      '-cfg_directory', path.join(this.artifacts, 'cfg'),
      '-state_directory', path.join(this.artifacts, 'sta'),
      '-pluginspath', path.join(this.mameDir, 'plugins'),
      ...(opts.extraArgs || []),
    ];
    if (opts.secondsToRun) args.push('-seconds_to_run', String(opts.secondsToRun));

    this.driver = driver;
    this.spawnError = null;
    this.proc = spawn(this.mameBin, args, {
      cwd: this.mameDir,
      env: {
        ...process.env,
        MAME_MCP_SOCKET: `domain.${this.sockPath}`,
        MAME_MCP_WORKDIR: this.artifacts,
        // Explicit for determinism; SDL would otherwise probe x11/wayland/
        // KMSDRM before falling back to offscreen. See PLAN.md 11.1.
        SDL_VIDEODRIVER: process.env.SDL_VIDEODRIVER || 'dummy',
        SDL_AUDIODRIVER: process.env.SDL_AUDIODRIVER || 'dummy',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const onOut = (chunk) => {
      const s = chunk.toString();
      this._log.push(s);
      if (this._log.length > 500) this._log.shift();
      this.emit('log', s);
    };
    this.proc.stdout.on('data', onOut);
    this.proc.stderr.on('data', onOut);

    // spawn() reports ENOENT/EACCES asynchronously via 'error'. Without a
    // listener Node treats it as an unhandled exception and kills the server.
    this.proc.on('error', (err) => {
      this.spawnError = err;
      this.ready = false;
      this.proc = null;
      for (const [, p] of this._pending) p.reject(err);
      this._pending.clear();
      this.emit('spawnerror', err);
    });

    this.proc.on('exit', (code, signal) => {
      this.ready = false;
      this.proc = null;
      this.emit('exit', { code, signal });
      for (const [, p] of this._pending) {
        p.reject(new Error(`MAME exited (code=${code} signal=${signal})`));
      }
      this._pending.clear();
    });

    try {
      await this._connect();
      return await this._waitReady(opts.readyTimeoutMs ?? 30000);
    } catch (e) {
      await this.stop();
      throw e;
    }
  }

  async _connect() {
    for (let i = 0; i < CONNECT_RETRIES; i++) {
      if (this.spawnError) {
        throw new Error(
          `could not launch MAME binary "${this.mameBin}" (${this.spawnError.code || this.spawnError.message}). ` +
          `Set MAME_BINARY / MAME_DIR to point at a built executable.`);
      }
      if (!this.proc) throw new Error(`MAME exited during startup:\n${this.logTail(40)}`);
      if (fs.existsSync(this.sockPath)) {
        try {
          const sock = await new Promise((resolve, reject) => {
            const s = net.connect(this.sockPath);
            s.once('connect', () => resolve(s));
            s.once('error', reject);
          });
          this.sock = sock;
          sock.setNoDelay(true);
          sock.on('data', (d) => this._onData(d));
          sock.on('error', (e) => this.emit('sockerror', e));
          return;
        } catch {
          // MAME binds the socket before it starts accepting; retry.
        }
      }
      await sleep(CONNECT_DELAY_MS);
    }
    throw new Error(`could not connect to ${this.sockPath}\n${this.logTail(40)}`);
  }

  _waitReady(timeoutMs) {
    if (this.ready) return Promise.resolve(true);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        reject(new Error(`timed out waiting for plugin ready\n${this.logTail(40)}`));
      }, timeoutMs);
      this.once('ready', () => { clearTimeout(t); resolve(true); });
    });
  }

  // ----------------------------------------------------------------- wire

  _onData(chunk) {
    this._buf += chunk.toString();
    let nl;
    while ((nl = this._buf.indexOf('\n')) >= 0) {
      const line = this._buf.slice(0, nl);
      this._buf = this._buf.slice(nl + 1);
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      this._onMessage(msg);
    }
  }

  _onMessage(msg) {
    if (msg.id !== undefined && msg.id !== null && this._pending.has(msg.id)) {
      const p = this._pending.get(msg.id);
      this._pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(msg.error.message || 'rpc error'));
      else p.resolve(msg.result);
      return;
    }

    switch (msg.method) {
      case 'mcp/ready':
        this.ready = true;
        this.info = msg.params;
        this.emit('ready', msg.params);
        break;
      case 'mcp/stopped':
        this.execState = 'stopped';
        this.lastStop = msg.params;
        this.emit('stopped', msg.params);
        break;
      case 'mcp/running':
        this.execState = msg.params?.state || 'running';
        this.emit('running', msg.params);
        break;
      case 'mcp/log':
        for (const l of msg.params?.lines || []) {
          this._consoleLog.push(l);
          if (this._consoleLog.length > 2000) this._consoleLog.shift();
        }
        break;
      case 'mcp/exiting':
        this.emit('exiting');
        break;
      default:
        this.emit('notification', msg);
    }
  }

  call(method, params = {}, timeoutMs = 20000) {
    if (!this.proc) return Promise.reject(new Error('no MAME session running; call session.start'));
    if (!this.sock) return Promise.reject(new Error('not connected to MAME'));

    const id = this._nextId++;
    const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(
          `timeout after ${timeoutMs}ms calling ${method}. ` +
          `If the CPU is running free this is normal for blocking operations; ` +
          `try exec.pause first.`));
      }, timeoutMs);
      this._pending.set(id, { resolve, reject, timer });
      this.sock.write(payload);
    });
  }

  // Long-poll for a stop event. Deliberately implemented here rather than in
  // MAME: blocking inside the emu loop would deadlock the pump.
  waitForStop(timeoutMs = 10000) {
    if (this.execState === 'stopped' && this.lastStop) {
      return Promise.resolve({ ...this.lastStop, already_stopped: true });
    }
    return new Promise((resolve) => {
      const t = setTimeout(() => {
        this.off('stopped', onStop);
        resolve({ reason: 'timeout', timed_out: true, timeout_ms: timeoutMs });
      }, timeoutMs);
      const onStop = (info) => { clearTimeout(t); resolve(info); };
      this.once('stopped', onStop);
    });
  }

  logTail(n = 40) {
    return this._log.join('').split('\n').slice(-n).join('\n');
  }

  consoleTail(n = 50) {
    return this._consoleLog.slice(-n);
  }

  async stop() {
    if (this.sock) { try { this.sock.destroy(); } catch { /* closing */ } this.sock = null; }
    if (this.proc) {
      const p = this.proc;
      p.kill('SIGTERM');
      await new Promise((resolve) => {
        const t = setTimeout(() => { try { p.kill('SIGKILL'); } catch { /* gone */ } resolve(); }, 3000);
        p.once('exit', () => { clearTimeout(t); resolve(); });
      });
      this.proc = null;
    }
    this.ready = false;
    try { fs.unlinkSync(this.sockPath); } catch { /* already gone */ }
  }
}
