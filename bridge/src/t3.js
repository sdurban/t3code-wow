// Client for the running T3 Code server: the same WebSocket RPC (Effect RPC, JSON
// frames) and HTTP API the desktop, web and mobile clients use.
//
// Auth is a scoped session token minted by `t3 auth session issue` (see auth.js).
// A local connection re-reads ~/.t3/userdata/server-runtime.json on every
// reconnect because the server moves when the app updates or restarts.

import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';

export const PROTOCOL = 2;

export function t3Home() {
  return process.env.T3CODE_HOME || path.join(os.homedir(), '.t3');
}

export function readRuntime() {
  const file = path.join(t3Home(), 'userdata', 'server-runtime.json');
  const runtime = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!runtime.origin) throw new Error(`no origin in ${file}`);
  return runtime;
}

export function normalizeT3Origin(value) {
  const error = 'T3_ORIGIN must be an HTTP or HTTPS origin without credentials, a path, or a pairing code';
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error(error);
  }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password
    || url.href !== `${url.origin}/`) {
    throw new Error(error);
  }
  return url.origin;
}

const WORKING = new Set(['preparing', 'queued', 'starting', 'running', 'waiting']);

function selectableProvider(p) {
  return p?.instanceId && p.enabled && p.installed && p.availability !== 'unavailable' && p.supportsTextGeneration !== false;
}

function selectableModel(m) {
  return m?.slug && !m.isLegacy;
}

const REASONING_OPTION = /effort|reason|think/i;

function reasoningDescriptor(model) {
  for (const option of model?.capabilities?.optionDescriptors || []) {
    if (option?.type !== 'select' || !option.id || !REASONING_OPTION.test(option.id)) continue;
    const injected = new Set(option.promptInjectedValues || []);
    const choices = (option.options || []).filter((choice) => choice?.id && !injected.has(choice.id));
    if (!choices.length) continue;
    return {
      id: option.id,
      label: option.label || 'Reasoning',
      default: choices.find((choice) => choice.id === option.currentValue)?.id || choices.find((choice) => choice.isDefault)?.id,
      choices: choices.map((choice) => ({ id: choice.id, label: choice.label || choice.id })),
    };
  }
}

function selectionOptions(selection) {
  const options = selection?.options;
  if (Array.isArray(options)) return options.filter((option) => option?.id);
  return Object.entries(options || {}).map(([id, value]) => ({ id, value }));
}

export function effectiveReasoning(model, selection) {
  const descriptor = reasoningDescriptor(model);
  const options = selectionOptions(selection);
  const selected = descriptor
    ? options.find((option) => option.id === descriptor.id)?.value ?? descriptor.default
    : options.find((option) => REASONING_OPTION.test(option.id) && typeof option.value === 'string')?.value;
  return typeof selected === 'string' ? selected : undefined;
}

function withReasoning(selection, model, effort) {
  if (!effort) return selection;
  const descriptor = reasoningDescriptor(model);
  if (!descriptor?.choices.some((choice) => choice.id === effort)) {
    throw new Error('That reasoning level is unavailable for this model');
  }
  if (effectiveReasoning(model, selection) === effort) return selection;
  return {
    ...selection,
    options: [...selectionOptions(selection).filter((option) => option.id !== descriptor.id), { id: descriptor.id, value: effort }],
  };
}

function sameModel(a, b) {
  return !!a?.instanceId && !!a.model && a.instanceId === b?.instanceId && a.model === b?.model;
}

// Collapse the server's thread fields into the handful the game needs.
export function threadStatus(t) {
  if (t.archivedAt || t.deletedAt) return 'archived';
  if (t.pendingRuntimeRequest) return 'input';
  if (t.activityRunStatus || WORKING.has(t.status)) return 'working';
  // Settled wins over an unreviewed plan: settling is how you say you're done with it.
  if (t.settledOverride === 'settled') return 'settled';
  if (t.hasActionableProposedPlan) return 'plan';
  if (t.status === 'failed' || t.lastError) return 'failed';
  return 'open';
}

export function isUnread(t) {
  const done = t.latestRunCompletedAt ? Date.parse(t.latestRunCompletedAt) : 0;
  const seen = t.lastVisitedAt ? Date.parse(t.lastVisitedAt) : 0;
  return done > seen;
}

export class T3Client extends EventEmitter {
  constructor({ tokenProvider, log = () => {}, originProvider = null, label = 'local' }) {
    super();
    this.tokenProvider = tokenProvider;
    // Additional machines have their own providers. The primary server can be
    // reached at a fixed address without running T3 Code on this machine.
    this.originProvider = originProvider || (async () => {
      if (process.env.T3_ORIGIN) return normalizeT3Origin(process.env.T3_ORIGIN);
      return readRuntime().origin;
    });
    this.label = label;
    this.log = log;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map(); // requestId -> { resolve, reject, chunks, onChunk }
    this.threads = new Map();
    this.projects = new Map();
    this.olderSettled = 0;
    this.config = null;
    this.state = 'disconnected';
    this.error = null;
    this.backoff = 1000;
    this.stopped = false;
    this.origin = null;
  }

  setState(state, error = null) {
    if (this.state === state && this.error === error) return;
    this.state = state;
    this.error = error;
    this.emit('state', state, error);
  }

  start() {
    this.stopped = false;
    this.connect();
  }

  stop() {
    this.stopped = true;
    try {
      this.ws?.close();
    } catch {}
  }

  async connect() {
    if (this.stopped) return;
    this.setState('connecting');
    try {
      this.origin = await this.originProvider();
      const runtime = { origin: this.origin };
      const token = await this.tokenProvider();
      const res = await fetch(new URL('/api/auth/websocket-ticket/rpc', runtime.origin), {
        method: 'POST',
        headers: { authorization: `Bearer ${token}` },
      });
      if (res.status === 401) {
        this.emit('unauthorized');
        throw new Error(`${this.label}: T3 rejected the bridge token (401)`);
      }
      if (!res.ok) throw new Error(`websocket ticket: HTTP ${res.status}`);
      const { ticket } = await res.json();
      const url = new URL('/ws', runtime.origin.replace(/^http/, 'ws'));
      url.searchParams.set('orchestrationProtocol', String(PROTOCOL));
      url.searchParams.set('wsTicket', ticket);
      await this.open(url);
    } catch (err) {
      this.setState('offline', err.message);
      this.scheduleReconnect();
    }
  }

  scheduleReconnect() {
    if (this.stopped) return;
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, 15000);
    setTimeout(() => this.connect(), delay);
  }

  open(url) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      this.ws = ws;
      let opened = false;
      ws.onopen = () => {
        opened = true;
        this.backoff = 1000;
        this.setState('connected');
        this.subscribeAll();
        resolve();
      };
      ws.onmessage = (ev) => this.onMessage(ev.data);
      ws.onerror = (ev) => {
        if (!opened) reject(new Error(ev.message || 'websocket error'));
      };
      ws.onclose = () => {
        if (this.ws !== ws) return;
        this.ws = null;
        for (const p of this.pending.values()) p.reject?.(new Error('connection closed'));
        this.pending.clear();
        if (opened) {
          this.setState('offline', 'connection closed');
          this.scheduleReconnect();
        }
      };
    });
  }

  send(obj) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) throw new Error('not connected to T3');
    this.ws.send(JSON.stringify(obj));
  }

  onMessage(data) {
    let msgs;
    try {
      msgs = [].concat(JSON.parse(data));
    } catch {
      return;
    }
    for (const m of msgs) {
      if (m._tag === 'Ping') {
        try {
          this.send({ _tag: 'Pong' });
        } catch {}
        continue;
      }
      const p = this.pending.get(m.requestId);
      if (!p) continue;
      if (m._tag === 'Chunk') {
        try {
          this.send({ _tag: 'Ack', requestId: m.requestId });
        } catch {}
        for (const v of m.values || []) {
          if (p.onChunk) p.onChunk(v);
          else p.chunks.push(v);
        }
      } else if (m._tag === 'Exit') {
        this.pending.delete(m.requestId);
        if (m.exit?._tag === 'Success') p.resolve(m.exit.value ?? p.chunks);
        else p.reject(new Error(describeFailure(m.exit)));
      } else if (m._tag === 'Defect') {
        this.pending.delete(m.requestId);
        p.reject(new Error(`T3 defect: ${JSON.stringify(m.defect).slice(0, 200)}`));
      }
    }
  }

  request(tag, payload, { onChunk, timeout = 20000 } = {}) {
    const id = String(this.nextId++);
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, chunks: [], onChunk };
      this.pending.set(id, entry);
      if (!onChunk && timeout) {
        const t = setTimeout(() => {
          if (this.pending.delete(id)) reject(new Error(`${tag} timed out`));
        }, timeout);
        entry.resolve = (v) => {
          clearTimeout(t);
          resolve(v);
        };
        entry.reject = (e) => {
          clearTimeout(t);
          reject(e);
        };
      }
      try {
        this.send({ _tag: 'Request', id, tag, payload, headers: [] });
      } catch (err) {
        this.pending.delete(id);
        reject(err);
      }
    });
  }

  subscribeAll() {
    this.request(
      'orchestration.subscribeShell',
      { omitIdleSubagents: true, omitOlderSettled: true },
      { onChunk: (v) => this.onShell(v), timeout: 0 },
    ).catch((err) => this.log(`shell subscription ended: ${err.message}`));
    this.request('subscribeServerConfig', {}, { onChunk: (v) => this.onConfig(v), timeout: 0 }).catch((err) =>
      this.log(`config subscription ended: ${err.message}`),
    );
  }

  onShell(item) {
    if (!item || typeof item !== 'object') return;
    if (item.kind === 'snapshot') {
      const snap = item.snapshot || {};
      // Follow-up snapshot frames can carry only projects (threads: []): keep threads.
      if (Array.isArray(snap.threads) && snap.threads.length > 0) {
        this.threads.clear();
        for (const t of snap.threads) if (!t.lineage?.parentThreadId) this.threads.set(t.id, t);
      }
      if (Array.isArray(snap.projects)) for (const p of snap.projects) this.projects.set(p.id, p);
      if (typeof snap.olderSettled === 'number') this.olderSettled = snap.olderSettled;
      else if (Array.isArray(snap.olderSettled?.counts)) {
        this.olderSettled = snap.olderSettled.counts.reduce((n, c) => n + (c.count || 0), 0);
      }
      this.emit('change', { kind: 'snapshot' });
    } else if (item.kind === 'thread.updated') {
      const t = item.thread;
      if (!t || t.lineage?.parentThreadId) return;
      const prev = this.threads.get(t.id);
      this.threads.set(t.id, t);
      if (!prev || prev.updatedAt !== t.updatedAt || threadStatus(prev) !== threadStatus(t)
        || !isDeepStrictEqual(prev.modelSelection, t.modelSelection)) {
        this.emit('change', { kind: 'thread', id: t.id, prev, thread: t });
      }
    } else if (item.kind === 'thread.removed') {
      const id = item.threadId || item.id || item.thread?.id;
      if (id && this.threads.delete(id)) this.emit('change', { kind: 'removed', id });
    } else if (item.kind === 'project.updated') {
      if (item.project) this.projects.set(item.project.id, item.project);
      this.emit('change', { kind: 'project' });
    } else if (item.kind === 'project.removed') {
      const id = item.projectId || item.id || item.project?.id;
      if (id) this.projects.delete(id);
      this.emit('change', { kind: 'project' });
    }
  }

  onConfig(item) {
    if (!item || typeof item !== 'object') return;
    if (item.type === 'snapshot' && item.config) {
      this.config = item.config;
    } else if (this.config && item.config) {
      this.config = { ...this.config, ...item.config };
    } else if (this.config) {
      const providers = item.providers || item.payload?.providers;
      const settings = item.payload?.settings;
      if (providers) this.config.providers = providers;
      if (settings) this.config.settings = settings;
    }
    this.emit('config');
  }

  // ---- reads ---------------------------------------------------------------

  async http(pathname) {
    const token = await this.tokenProvider();
    const res = await fetch(new URL(pathname, this.origin || (await this.originProvider())), {
      headers: { authorization: `Bearer ${token}`, 'x-t3-orchestration-protocol': String(PROTOCOL) },
    });
    if (!res.ok) throw new Error(`${pathname}: HTTP ${res.status}`);
    return res.json();
  }

  threadProjection(threadId) {
    return this.http(`/api/orchestration/threads/${encodeURIComponent(threadId)}/bounded`).then((d) => d.projection);
  }

  defaultModelSelection(projectId) {
    return this.projects.get(projectId)?.defaultModelSelection || this.config?.settings?.defaultModelSelection;
  }

  modelCatalog() {
    return (this.config?.providers || []).filter(selectableProvider).map((provider) => ({
      id: provider.instanceId,
      label: provider.displayName || provider.instanceId,
      locked: provider.requiresNewThreadForModelChange === true || undefined,
      models: (provider.models || []).filter(selectableModel).map((model) => ({
        id: model.slug, label: model.shortName || model.name || model.slug, effort: reasoningDescriptor(model),
      })),
    })).filter((provider) => provider.models.length);
  }

  validateModelSelection(selection) {
    if (!selection.instanceId || !selection.model) throw new Error('Choose an agent and a model');
    const provider = this.config?.providers?.find((p) => p?.instanceId === selection.instanceId);
    const model = selectableProvider(provider) && provider.models?.find((m) => selectableModel(m)
      && (m.slug === selection.model || m.aliases?.includes(selection.model)));
    if (!model) {
      throw new Error('That agent or model is unavailable on this T3 Code machine');
    }
    return model;
  }

  // ---- writes --------------------------------------------------------------

  dispatch(command) {
    return this.request('orchestration.dispatchCommand', { commandId: randomUUID(), ...command });
  }

  async setThreadModel(threadId, selection, effort) {
    const thread = this.threads.get(threadId);
    if (!thread) throw new Error('That thread is no longer available');
    const same = sameModel(thread.modelSelection, selection);
    if (same && !effort) return;
    const model = this.validateModelSelection(selection);
    const base = same ? thread.modelSelection : selection;
    const modelSelection = withReasoning(base, model, effort);
    if (same && modelSelection === base) return;
    // T3 can detach the live provider session even for a same-agent model change.
    if (thread.activeRunId || thread.activityRunStatus || WORKING.has(thread.status) || thread.pendingRuntimeRequest) {
      throw new Error('Wait for the current run or request to finish before changing the model selection');
    }
    const instanceId = thread.modelSelection?.instanceId || thread.providerInstanceId;
    const switching = instanceId && instanceId !== modelSelection.instanceId;
    if (switching) {
      const current = this.config?.providers?.find((p) => p?.instanceId === instanceId);
      if (current?.requiresNewThreadForModelChange) throw new Error('Start a new thread to switch from this agent');
    }
    return this.dispatch({ type: switching ? 'provider.switch' : 'thread.model-selection.set', threadId, modelSelection });
  }

  sendMessage(threadId, text, mode = 'auto', attachments = []) {
    const t = this.threads.get(threadId);
    const busy = t && threadStatus(t) === 'working';
    let dispatchMode = { type: 'start_immediately' };
    if (mode === 'steer' && t?.activeRunId) dispatchMode = { type: 'steer_active', targetRunId: t.activeRunId };
    else if (busy) dispatchMode = { type: 'queue_after_active' };
    return this.dispatch({
      type: 'message.dispatch',
      threadId,
      messageId: randomUUID(),
      text,
      attachments,
      createdBy: 'user',
      creationSource: 'web',
      dispatchMode,
    });
  }

  // opts: { title, modelSelection, effort, runtimeMode, interactionMode }
  launchThread(projectId, text, attachments = [], opts = {}) {
    const settings = this.config?.settings || {};
    const defaultSelection = this.defaultModelSelection(projectId);
    const selected = opts.modelSelection;
    const base = selected && !sameModel(selected, defaultSelection) ? selected : defaultSelection;
    if (!base) throw new Error('T3 has no default model configured');
    const model = selected || opts.effort ? this.validateModelSelection(base) : undefined;
    const modelSelection = withReasoning(base, model, opts.effort);
    const firstLine = text.split('\n')[0].trim();
    const title = firstLine.length > 60 ? firstLine.slice(0, 57) + '...' : firstLine || 'New thread';
    return this.request('orchestration.launchThread', {
      commandId: randomUUID(),
      creationSource: 'web',
      projectId,
      title: opts.title || title,
      generateTitle: !opts.title,
      modelSelection,
      runtimeMode: opts.runtimeMode || settings.defaultRuntimeMode || 'full-access',
      interactionMode: opts.interactionMode || 'default',
      workspaceStrategy: { type: 'root' },
      initialMessage: { messageId: randomUUID(), text, attachments },
    }, { timeout: 60000 });
  }

  // Upload an image the way the T3 app does: ask for a signed upload URL, POST the
  // bytes there, then reference the attachment id in the message.
  async uploadImage(data, name, mimeType) {
    const { attachmentId, relativeUrl } = await this.request('attachments.createUploadUrl', {
      type: 'image',
      name,
      mimeType,
      sizeBytes: data.length,
    });
    const res = await fetch(new URL(relativeUrl, this.origin), {
      method: 'POST',
      headers: { 'content-type': mimeType, 'content-length': String(data.length) },
      body: data,
    });
    if (!res.ok) throw new Error(`screenshot upload failed: HTTP ${res.status}`);
    return { type: 'image', id: attachmentId, name, mimeType, sizeBytes: data.length };
  }

  interrupt(threadId) {
    const t = this.threads.get(threadId);
    if (!t?.activeRunId) throw new Error('nothing is running in that thread');
    return this.dispatch({ type: 'run.interrupt', threadId, runId: t.activeRunId, holdQueue: true });
  }

  respondApproval(threadId, requestId, decision) {
    return this.dispatch({ type: 'runtime-request.respond', threadId, requestId, decision });
  }

  respondAnswers(threadId, requestId, answers) {
    return this.dispatch({ type: 'runtime-request.respond', threadId, requestId, answers });
  }

  settle(threadId) {
    return this.dispatch({ type: 'thread.settle', threadId });
  }

  unsettle(threadId) {
    return this.dispatch({ type: 'thread.unsettle', threadId, reason: 'user' });
  }

  archive(threadId) {
    return this.dispatch({ type: 'thread.archive', threadId });
  }

  visit(threadId) {
    return this.dispatch({ type: 'thread.visit', threadId, visitedAt: new Date().toISOString() });
  }
}

function describeFailure(exit) {
  const cause = exit?.cause;
  const first = Array.isArray(cause) ? cause[0] : cause;
  const err = first?.error || first?.defect || first;
  if (!err) return 'T3 request failed';
  return err.message || err.reason || err._tag || JSON.stringify(err).slice(0, 200);
}
