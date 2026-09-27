// JSON-lines logger. One object per line on stdout so pm2 and log shippers can parse it.

export type Level = "debug" | "info" | "warn" | "error";
export type Fields = Record<string, unknown>;

export interface Logger {
  debug(msg: string, fields?: Fields): void;
  info(msg: string, fields?: Fields): void;
  warn(msg: string, fields?: Fields): void;
  error(msg: string, fields?: Fields): void;
  child(base: Fields): Logger;
}

const levelRank: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function replacer(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Error) {
    const out: Fields = { name: value.name, message: value.message };
    if ("shortMessage" in value && typeof value.shortMessage === "string") out.shortMessage = value.shortMessage;
    if (value.cause !== undefined) out.cause = value.cause;
    return out;
  }
  return value;
}

export function formatLine(level: Level, msg: string, fields: Fields, now: () => Date = () => new Date()): string {
  return JSON.stringify({ ts: now().toISOString(), level, msg, ...fields }, replacer);
}

export interface LoggerOptions {
  minLevel?: Level;
  write?: (line: string) => void;
  now?: () => Date;
}

export function createLogger(opts: LoggerOptions = {}, base: Fields = {}): Logger {
  const minLevel = opts.minLevel ?? "info";
  const write = opts.write ?? ((line: string) => process.stdout.write(line + "\n"));
  const now = opts.now ?? (() => new Date());
  const emit = (level: Level, msg: string, fields?: Fields) => {
    if (levelRank[level] < levelRank[minLevel]) return;
    write(formatLine(level, msg, { ...base, ...fields }, now));
  };
  return {
    debug: (msg, fields) => emit("debug", msg, fields),
    info: (msg, fields) => emit("info", msg, fields),
    warn: (msg, fields) => emit("warn", msg, fields),
    error: (msg, fields) => emit("error", msg, fields),
    child: (extra) => createLogger(opts, { ...base, ...extra }),
  };
}

export const silentLogger: Logger = {
  debug: () => {},
  info: () => {},
  warn: () => {},
  error: () => {},
  child: () => silentLogger,
};
