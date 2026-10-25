import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createHash } from "node:crypto";

const chunks = Number(process.argv[2] ?? 3000);
const kind = process.argv[3] ?? "reasoning";
const serialization = process.argv[4] ?? "none";
const { ClaudeAgentClient } = await import("../agent.js");
const { TimelineProjection } = await import("../../../timeline-projection.js");
const { AgentStreamCoalescer } = await import("../../../agent-stream-coalescer.js");
const logger = {
  child() {
    return this;
  },
  trace() {},
  debug() {},
  info() {},
  warn() {},
  error() {},
};
const client = new ClaudeAgentClient({ logger });
const session = await client.createSession({ provider: "claude", cwd: "/tmp", modeId: "auto" });
const assembler = session.timelineAssembler;
const projection = new TimelineProjection();
let seq = 0;
const coalescer = new AgentStreamCoalescer({
  now: () => 1000 + seq * 100,
  timers: { setTimeout, clearTimeout },
  onFlush: (event) => {
    projection.append({ seq: ++seq, timestamp: "2026-10-20T00:00:00.000Z", item: event.item });
    if (serialization === "events") JSON.stringify(event);
    if (serialization === "timeline") JSON.stringify(projection.getRows());
  },
});
function consume(event) {
  const items = assembler.consume({ message: { type: "stream_event", event }, runId: "test-turn" });
  for (const item of items)
    coalescer.handle("test-agent", {
      type: "timeline",
      item,
      provider: "claude",
      turnId: "test-turn",
    });
}
async function collect() {
  for (let i = 0; i < 3; i++) {
    global.gc();
    await delay(20);
  }
  return process.memoryUsage().heapUsed;
}
const baseline = await collect();
const started = performance.now();
consume({ type: "message_start", message: { id: "test-message" } });
for (let i = 0; i < chunks; i++) {
  const text = Buffer.from(`chunk-${i.toString(16).padStart(8, "0")}|`.padEnd(96, "x")).toString();
  consume({
    type: "content_block_delta",
    delta:
      kind === "reasoning"
        ? { type: "thinking_delta", thinking: text }
        : { type: "text_delta", text },
  });
}
consume({ type: "message_stop", message_id: "test-message" });
coalescer.flushAll();
const after = await collect();
const row = projection.getRows()[0];
assert.equal(row.item.text.length, chunks * 96);
assert.equal(projection.getRows().length, 1);
assert.equal(assembler.messages.size, 0);
const retainedWhileTimelineAlive = after - baseline;
const result = {
  node: process.version,
  chunks,
  kind,
  textCharacters: row.item.text.length,
  retainedBytes: retainedWhileTimelineAlive,
  amplification: retainedWhileTimelineAlive / row.item.text.length,
  elapsedMs: performance.now() - started,
  timelineRows: 1,
  assemblerMessagesAfterStop: assembler.messages.size,
  serialization,
  contentSha256: createHash("sha256").update(row.item.text).digest("hex"),
};
console.log(JSON.stringify(result));
// Keep the legitimate output reachable through the final measurement.
assert.ok(row.item.text.startsWith("chunk-00000000|"));
