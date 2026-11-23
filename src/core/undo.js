export class UndoStack {
  #s = [];
  push(label, undo) {
    this.#s.push({ label, undo });
    if (this.#s.length > 100) this.#s.shift();
  }
  async undo() {
    const e = this.#s.pop();
    return e ? { label: e.label, result: await e.undo() } : null;
  }
  get canUndo() { return this.#s.length > 0; }
  peekLabel() { return this.#s.at(-1)?.label ?? null; }
}
