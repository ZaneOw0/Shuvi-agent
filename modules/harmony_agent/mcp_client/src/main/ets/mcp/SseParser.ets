export interface SseEvent {
  event: string;
  data: string;
  id: string;
}

export class SseParser {
  private buffer: string = '';
  private eventName: string = '';
  private eventId: string = '';
  private dataLines: string[] = [];

  push(chunk: string): SseEvent[] {
    this.buffer += chunk;
    const events: SseEvent[] = [];
    let newlineIndex: number = this.findNewline(this.buffer);
    while (newlineIndex >= 0) {
      let line: string = this.buffer.substring(0, newlineIndex);
      const consumed: number = newlineIndex + 1;
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.buffer = this.buffer.substring(consumed);
      const event: SseEvent | undefined = this.consumeLine(line);
      if (event !== undefined) {
        events.push(event);
      }
      newlineIndex = this.findNewline(this.buffer);
    }
    return events;
  }

  finish(): SseEvent[] {
    const events: SseEvent[] = [];
    if (this.buffer.length > 0) {
      const event: SseEvent | undefined = this.consumeLine(this.buffer);
      this.buffer = '';
      if (event !== undefined) {
        events.push(event);
      }
    }
    const finalEvent: SseEvent | undefined = this.dispatch();
    if (finalEvent !== undefined) {
      events.push(finalEvent);
    }
    return events;
  }

  reset(): void {
    this.buffer = '';
    this.eventName = '';
    this.eventId = '';
    this.dataLines = [];
  }

  private findNewline(value: string): number {
    return value.indexOf('\n');
  }

  private consumeLine(line: string): SseEvent | undefined {
    if (line.length === 0) {
      return this.dispatch();
    }
    if (line.startsWith(':')) {
      return undefined;
    }
    const colon: number = line.indexOf(':');
    let field: string = line;
    let value: string = '';
    if (colon >= 0) {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
    }
    if (field === 'event') {
      this.eventName = value;
    } else if (field === 'data') {
      this.dataLines.push(value);
    } else if (field === 'id' && value.indexOf('\u0000') < 0) {
      this.eventId = value;
    }
    return undefined;
  }

  private dispatch(): SseEvent | undefined {
    if (this.dataLines.length === 0) {
      this.eventName = '';
      return undefined;
    }
    const event: SseEvent = {
      event: this.eventName.length > 0 ? this.eventName : 'message',
      data: this.dataLines.join('\n'),
      id: this.eventId
    };
    this.eventName = '';
    this.dataLines = [];
    return event;
  }
}
