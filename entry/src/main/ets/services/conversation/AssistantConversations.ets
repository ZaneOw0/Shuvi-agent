import util from '@ohos.util';
import { ChatMessage } from '../../model/AssistantModels';
import { CalendarCreatedSummary } from '../calendar/CalendarPresentation';
import { VoiceClip } from '../speech/VoiceAudio';
import { AssistantMemory, AssistantMemoryState, parseAssistantMemory } from './AssistantMemory';
import { ChatKnowledgeSnapshot, copyChatKnowledgeSnapshot } from '../../model/ChatKnowledgeModels';

/** One row of the conversation list (newest first). */
export class ConversationSummary {
  id: string = '';
  title: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
}
/**
 * A stored conversation: what the user saw plus what the model remembers. Image bytes never enter the record; a sent
 * picture is kept as a separate local file (see ChatImageStore) and the record names that file.
 */
export class ConversationRecord {
  id: string = '';
  title: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
  messagesJson: string = '[]';
  memoryJson: string = '';
}
export interface ConversationPersistencePort {
  open(): Promise<void>;
  close(): Promise<void>;
  /** Newest first. */
  list(): Promise<ConversationSummary[]>;
  load(id: string): Promise<ConversationRecord | undefined>;
  save(record: ConversationRecord): Promise<void>;
  remove(id: string): Promise<void>;
}
export class ConversationView {
  /** The local store is open; false before opening or when it failed (the conversation then lives in memory only). */
  ready: boolean = false;
  currentId: string = '';
  list: ConversationSummary[] = [];
  /** Non-empty when the last save or load failed. */
  message: string = '';
}

/** Where sent chat pictures are kept on this device; the conversation record only stores their file names. */
export interface ConversationImagePort {
  /** Displayable URI of a kept picture, or undefined when the file is gone. */
  uri(name: string): string | undefined;
  remove(names: string[]): void;
}

/** File name of a kept chat picture (no directories, so a damaged record can never point elsewhere). */
export function validChatImageName(name: string): boolean {
  return /^chat-image-[0-9a-f-]{36}\.(jpg|png|webp)$/.test(name);
}

/** Display message as stored: no picker URI and no image bytes, only that an image was attached and its kept file. */
class StoredChatMessage {
  id: string = '';
  isUser: boolean = false;
  text: string = '';
  voice?: VoiceClip;
  image?: boolean;
  imageFile?: string;
  calendar?: CalendarCreatedSummary;
  knowledgeSources?: ChatKnowledgeSnapshot;
}

const MAX_TITLE: number = 24;
const MAX_TEXT: number = 20000;

function imageFiles(messages: StoredChatMessage[]): string[] {
  const names: string[] = [];
  for (const message of messages) {
    if (message.imageFile !== undefined && validChatImageName(message.imageFile)) names.push(message.imageFile);
  }
  return names;
}

function storedMessage(message: ChatMessage): StoredChatMessage | undefined {
  // Demo search turns are not part of a real conversation.
  if (message.searchId !== undefined) return undefined;
  const stored: StoredChatMessage = new StoredChatMessage();
  stored.id = message.id; stored.isUser = message.isUser; stored.text = message.text.slice(0, MAX_TEXT);
  if (message.voice !== undefined) {
    const voice: VoiceClip = new VoiceClip(); voice.id = message.voice.id; voice.path = message.voice.path;
    voice.durationMs = message.voice.durationMs; voice.createdAt = message.voice.createdAt; stored.voice = voice;
  }
  if (message.image !== undefined || message.imageMissing === true) stored.image = true;
  if (message.imageFile !== undefined && validChatImageName(message.imageFile)) stored.imageFile = message.imageFile;
  if (message.calendar !== undefined) stored.calendar = JSON.parse(JSON.stringify(message.calendar)) as CalendarCreatedSummary;
  if (!message.isUser) stored.knowledgeSources = copyChatKnowledgeSnapshot(message.knowledgeSources);
  return stored;
}

function objectValue(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function parseMessages(json: string): StoredChatMessage[] {
  const result: StoredChatMessage[] = [];
  try {
    const value: Object = JSON.parse(json) as Object;
    if (!Array.isArray(value)) return result;
    for (const raw of value as Object[]) {
      if (!objectValue(raw)) continue;
      const item: StoredChatMessage = raw as StoredChatMessage;
      if (typeof item.id !== 'string' || typeof item.isUser !== 'boolean' || typeof item.text !== 'string') continue;
      const message: StoredChatMessage = new StoredChatMessage();
      message.id = item.id; message.isUser = item.isUser; message.text = item.text.slice(0, MAX_TEXT);
      const voice: VoiceClip | undefined = item.voice;
      if (voice !== undefined && objectValue(voice) && typeof voice.id === 'string' && typeof voice.path === 'string' &&
        typeof voice.durationMs === 'number' && typeof voice.createdAt === 'number') {
        const clip: VoiceClip = new VoiceClip(); clip.id = voice.id; clip.path = voice.path;
        clip.durationMs = voice.durationMs; clip.createdAt = voice.createdAt; message.voice = clip;
      }
      if (item.image === true) message.image = true;
      if (typeof item.imageFile === 'string' && validChatImageName(item.imageFile)) {
        message.imageFile = item.imageFile; message.image = true;
      }
      if (!item.isUser) message.knowledgeSources = copyChatKnowledgeSnapshot(item.knowledgeSources);
      const calendar: CalendarCreatedSummary | undefined = item.calendar;
      if (calendar !== undefined && objectValue(calendar) && typeof calendar.title === 'string' &&
        typeof calendar.when === 'string' && typeof calendar.reminder === 'string' && typeof calendar.eventId === 'number' &&
        typeof calendar.reminderConfigured === 'boolean') {
        const summary: CalendarCreatedSummary = new CalendarCreatedSummary();
        summary.title = calendar.title; summary.when = calendar.when; summary.reminder = calendar.reminder;
        summary.eventId = calendar.eventId; summary.reminderConfigured = calendar.reminderConfigured; message.calendar = summary;
      }
      result.push(message);
    }
  } catch { /* A damaged row shows as an empty conversation instead of breaking the page. */ }
  return result;
}

/** List title: the first thing the user said (typed text, else the kind of message). */
export function conversationTitle(messages: ChatMessage[]): string {
  const first: ChatMessage | undefined = messages.find((item: ChatMessage): boolean => item.isUser);
  if (first === undefined) return '新对话';
  const text: string = first.text.replace(/\s+/g, ' ').trim();
  if (text.length > 0) return text.length > MAX_TITLE ? text.slice(0, MAX_TITLE) + '…' : text;
  if (first.image !== undefined || first.imageMissing === true) return '图片';
  if (first.voice !== undefined) return '语音消息';
  return '新对话';
}

/**
 * All saved assistant conversations. The current conversation's display messages (from the page) and model memory
 * (from AssistantMemory) are written together; switching or starting a new conversation never loses either.
 * Saves are serialized and coalesced: the latest state wins and a pending save finishes before a switch.
 */
export class AssistantConversations {
  private readonly memory: AssistantMemory;
  private readonly clock: () => number;
  private readonly ids: () => string;
  private port?: ConversationPersistencePort;
  private opening?: Promise<ChatMessage[]>;
  private ready: boolean = false;
  private currentId: string = '';
  private createdAt: number = 0;
  private messages: StoredChatMessage[] = [];
  private title: string = '新对话';
  private list: ConversationSummary[] = [];
  private message: string = '';
  /** The current conversation has changes that are not saved yet. */
  private dirty: boolean = false;
  /** Final states of conversations the page has left, saved before anything newer. */
  private pending: ConversationRecord[] = [];
  private writing?: Promise<void>;
  private loads: number = 0;
  private listener?: (view: ConversationView) => void;
  private images?: ConversationImagePort;

  constructor(memory: AssistantMemory, clock: () => number = (): number => Date.now(),
    ids: () => string = (): string => util.generateRandomUUID()) {
    this.memory = memory; this.clock = clock; this.ids = ids;
    this.memory.onChange((): void => { if (this.currentId.length > 0) this.scheduleSave(); });
  }

  /** Kept chat pictures: restored messages show them again and deleting a conversation deletes them. */
  useImages(images: ConversationImagePort): void { this.images = images; }
  attach(listener: (view: ConversationView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; }
  view(): ConversationView {
    const view: ConversationView = new ConversationView();
    view.ready = this.ready; view.currentId = this.currentId; view.message = this.message;
    view.list = this.list.map((item: ConversationSummary): ConversationSummary => {
      const copy: ConversationSummary = new ConversationSummary();
      copy.id = item.id; copy.title = item.title; copy.createdAt = item.createdAt; copy.updatedAt = item.updatedAt; return copy;
    });
    return view;
  }
  private publish(): void { this.listener?.(this.view()); }

  /**
   * Opens the store once and restores the most recent conversation (display messages and model memory).
   * If the store cannot open, the app keeps working with an unsaved in-memory conversation.
   */
  open(port: ConversationPersistencePort): Promise<ChatMessage[]> {
    if (this.opening === undefined) this.opening = this.openOnce(port);
    return this.opening;
  }
  private async openOnce(port: ConversationPersistencePort): Promise<ChatMessage[]> {
    try {
      await port.open();
      this.port = port; this.ready = true;
      this.list = await port.list();
      // A conversation started before the store opened is kept as the current one.
      if (this.currentId.length > 0 || this.messages.length > 0 || this.list.length === 0) {
        if (this.messages.length > 0) this.scheduleSave();
        this.publish(); return this.displayMessages();
      }
      const record: ConversationRecord | undefined = await port.load(this.list[0].id);
      if (record !== undefined) this.apply(record);
      this.publish(); return this.displayMessages();
    } catch {
      this.ready = false; this.message = '本机对话记录打不开，这段对话只保存在本次运行中。';
      this.publish(); return this.displayMessages();
    }
  }

  currentConversationId(): string { return this.currentId; }

  /** Called by the page whenever its message list changes; the first message creates the conversation. */
  saveMessages(messages: ChatMessage[]): void {
    const stored: StoredChatMessage[] = [];
    for (const message of messages) {
      const item: StoredChatMessage | undefined = storedMessage(message);
      if (item !== undefined) stored.push(item);
    }
    if (stored.length === 0 && this.currentId.length === 0) return;
    this.messages = stored; this.title = conversationTitle(messages);
    if (this.currentId.length === 0) { this.currentId = this.ids(); this.createdAt = this.clock(); }
    this.scheduleSave();
  }

  /**
   * Keeps the current conversation (its last state is queued for saving) and starts an empty one with empty model
   * memory. Synchronous, so a message sent right afterwards can never land in the previous conversation.
   */
  startNew(): void {
    this.detachCurrent(); this.reset(); this.message = ''; this.publish();
  }

  /** Restores another conversation; resolves undefined (with an empty current conversation) when it cannot be read. */
  async switchTo(id: string): Promise<ChatMessage[] | undefined> {
    if (id === this.currentId) return this.displayMessages();
    this.detachCurrent(); this.reset();
    let record: ConversationRecord | undefined = undefined;
    if (this.port !== undefined && this.ready) {
      try { record = await this.port.load(id); } catch { record = undefined; }
    }
    if (record === undefined || this.currentId.length > 0) {
      this.message = '这段对话没能读取，可能已被删除。'; this.publish(); return undefined;
    }
    this.apply(record); this.message = ''; this.publish();
    return this.displayMessages();
  }

  /**
   * Deletes a conversation and the pictures kept for it; returns true when it was the current one (the page then shows
   * a new empty conversation).
   */
  async remove(id: string): Promise<boolean> {
    const current: boolean = id === this.currentId;
    let pictures: string[] = current ? imageFiles(this.messages) : [];
    if (current) { this.dirty = false; this.reset(); }
    for (const record of this.pending) {
      if (record.id === id) pictures = pictures.concat(imageFiles(parseMessages(record.messagesJson)));
    }
    this.pending = this.pending.filter((item: ConversationRecord): boolean => item.id !== id);
    // A save of this conversation that is already running must finish first, or it would bring the row back.
    await this.flush();
    if (this.port !== undefined && this.ready) {
      if (!current) {
        try {
          const record: ConversationRecord | undefined = await this.port.load(id);
          if (record !== undefined) pictures = pictures.concat(imageFiles(parseMessages(record.messagesJson)));
        } catch { /* The row is still deleted; pictures it named stay on the device. */ }
      }
      try { await this.port.remove(id); } catch { this.message = '删除没有完成，请稍后再试。'; this.publish(); return current; }
    }
    try { this.images?.remove(pictures); } catch { /* A picture that could not be deleted never blocks the conversation list. */ }
    this.list = this.list.filter((item: ConversationSummary): boolean => item.id !== id);
    this.message = ''; this.publish();
    return current;
  }

  /** Waits for every accepted save. */
  async flush(): Promise<void> {
    while (this.writing !== undefined) await this.writing;
  }

  private reset(): void {
    this.currentId = ''; this.createdAt = 0; this.messages = []; this.title = '新对话';
    this.memory.restore(new AssistantMemoryState());
  }

  private apply(record: ConversationRecord): void {
    this.currentId = record.id; this.createdAt = record.createdAt; this.title = record.title;
    this.messages = parseMessages(record.messagesJson);
    this.memory.restore(parseAssistantMemory(record.memoryJson));
    this.loads++;
  }

  /** Restored messages get fresh ids so they never collide with ids the page creates later. */
  private displayMessages(): ChatMessage[] {
    const prefix: string = 'h' + this.loads + '-';
    return this.messages.map((item: StoredChatMessage, index: number): ChatMessage => {
      const message: ChatMessage = { id: prefix + index + '-' + item.id.slice(0, 40), isUser: item.isUser, text: item.text };
      if (item.voice !== undefined) message.voice = item.voice;
      const picture: string | undefined = item.imageFile === undefined ? undefined : this.pictureUri(item.imageFile);
      if (picture !== undefined && item.imageFile !== undefined) { message.image = picture; message.imageFile = item.imageFile; }
      else if (item.image === true) message.imageMissing = true;
      if (item.calendar !== undefined) message.calendar = item.calendar;
      if (!item.isUser) message.knowledgeSources = copyChatKnowledgeSnapshot(item.knowledgeSources);
      return message;
    });
  }

  private pictureUri(name: string): string | undefined {
    try { return this.images?.uri(name); } catch { return undefined; }
  }

  private record(): ConversationRecord {
    const record: ConversationRecord = new ConversationRecord();
    record.id = this.currentId; record.title = this.title; record.createdAt = this.createdAt; record.updatedAt = this.clock();
    record.messagesJson = JSON.stringify(this.messages); record.memoryJson = JSON.stringify(this.memory.snapshot());
    return record;
  }

  /** Queues the current conversation's unsaved state before the page moves to another conversation. */
  private detachCurrent(): void {
    if (!this.dirty) return;
    this.dirty = false;
    if (this.port === undefined || !this.ready || this.currentId.length === 0) return;
    this.pending.push(this.record()); this.kick();
  }

  private scheduleSave(): void { this.dirty = true; this.kick(); }
  private kick(): void {
    if (this.writing !== undefined) return;
    this.writing = this.drain().finally((): void => { this.writing = undefined; });
  }
  private async drain(): Promise<void> {
    while (this.pending.length > 0 || this.dirty) {
      let record: ConversationRecord | undefined = this.pending.shift();
      if (record === undefined) {
        this.dirty = false;
        if (this.port === undefined || !this.ready || this.currentId.length === 0) continue;
        record = this.record();
      }
      if (this.port === undefined) continue;
      const saved: ConversationRecord = record;
      try {
        await this.port.save(saved);
        const summary: ConversationSummary = new ConversationSummary();
        summary.id = saved.id; summary.title = saved.title; summary.createdAt = saved.createdAt; summary.updatedAt = saved.updatedAt;
        this.list = [summary].concat(this.list.filter((item: ConversationSummary): boolean => item.id !== saved.id));
        if (this.message.length > 0) this.message = '';
      } catch {
        this.message = '对话没能保存到本机，重启后可能看不到这段记录。';
      }
      this.publish();
    }
  }
}
