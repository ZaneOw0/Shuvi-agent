export class SecretRedactor {
  static redact(value: string, secrets: string[]): string {
    let redacted: string = value;
    for (let i: number = 0; i < secrets.length; i++) {
      if (secrets[i].length > 0) {
        redacted = redacted.split(secrets[i]).join('[REDACTED]');
      }
    }
    return redacted;
  }
}
