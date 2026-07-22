#!/usr/bin/env node
// Semantic policy for the crew kill-guard: does a shell command run a broad
// name-pattern process kill that could reach processes OUTSIDE the task
// worktree it runs in?
//
// Incident (2026-07-22, backlog fm-crew-cleanup-broad-kill): a no-mistakes
// test-step agent, cleaning up its own dev server inside a task worktree, ran
// `pkill -f 'concurrently.*dev'` and killed the captain's pre-existing
// `npm run dev` in a completely different checkout. A name-pattern kill
// matches by command line across the whole machine; nothing scopes it to the
// worktree the agent works in. This policy denies exactly that class of
// command; the worktree-resident hook transport lives in
// bin/fm-kill-pretool-check.sh. See docs/kill-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted
// command; it inspects lexical command positions only.
//
// Deny/allow shape (docs/kill-guard.md owns the human-readable contract):
//   DENY  broad-kill          executed pkill/killall whose arguments never
//                             reference the worktree path, an executed kill
//                             consuming unscoped pgrep output (substitution,
//                             tainted variable, or pipeline into xargs kill),
//                             or a literal nested shell/eval payload doing so.
//   DENY  unclassifiable-kill unsupported or untokenizable syntax whose raw
//                             bytes carry a name-pattern kill verb.
//   ALLOW everything else     kill-by-PID, worktree-scoped patterns
//                             (containing the worktree path, $PWD, or
//                             $(pwd)), standalone read-only pgrep, and any
//                             mention of a kill verb in a data position.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Kill commands that select victims by NAME or command-line PATTERN, the whole
// hazard class. Plain `kill` selects by PID and is only dangerous when it
// consumes pattern-matched PIDs, which is handled separately below.
const NAME_KILLS = new Set(["pkill", "killall"]);

function reasons(worktree) {
  return {
    "broad-kill":
      `a name-pattern process kill from a task worktree can match processes outside the worktree (a pkill -f once killed the captain's own dev server in another checkout). Tear down only your own processes: kill recorded PIDs (e.g. kill "$(cat .fm-dev.pid)"), or scope the pattern to this worktree's absolute path (e.g. pkill -f ${JSON.stringify(`${worktree}/...`)}).`,
    "unclassifiable-kill":
      "unsupported or malformed shell syntax contains a name-pattern process kill and cannot be safely classified; run the kill as a plain single command scoped to a recorded PID or to this worktree's absolute path",
  };
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function normalizeLineContinuations(source) {
  return source.replace(/\\\r?\n/g, "");
}

// The fail-closed backstop trigger: raw bytes that name a pattern-kill verb.
// `\bkill\b` alone would be far too eager (kill-by-PID is fine and common), so
// bare kill only counts when pgrep also appears - the "kill the pgrep matches"
// shape. "skill"/"skills" never match: \b needs a non-word boundary and the
// s-k join is word-word.
function rawMentionsNameKill(command) {
  const normalized = normalizeLineContinuations(command);
  if (/\b(?:pkill|killall)\b/.test(normalized)) return true;
  return /\bkill\b/.test(normalized) && /\bpgrep\b/.test(normalized);
}

// A word is worktree-scoped when its literal bytes reference the task worktree
// path, or reference the shell's own cwd ($PWD / $(pwd)), which crew rules pin
// inside the worktree. The classifier never expands anything; it matches bytes.
// Duplicate slashes are collapsed on both sides before the substring test (the
// worktree side via path.normalize, the word side here), so a doubled slash in
// either spelling of the same path never breaks the match.
function collapseSlashes(value) {
  return value.replace(/\/{2,}/g, "/");
}

function wordIsScoped(word, worktree) {
  if (!word) return false;
  if (worktree && collapseSlashes(word.value).includes(worktree)) return true;
  if (/\$PWD(?![A-Za-z0-9_])|\$\{PWD\}/.test(word.value)) return true;
  return word.subs.some((sub) => /^\s*pwd\s*$/.test(sub.content));
}

function isAssignment(value) {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(value);
}

function assignmentName(word) {
  const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
  return match ? match[1] : "";
}

function wordReferencesAny(word, names) {
  if (!word || names.size === 0) return false;
  for (const match of word.value.matchAll(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g)) {
    if (names.has(match[1] || match[2])) return true;
  }
  return false;
}

// Literal sh/bash/zsh -c payload word, if present, for recursive
// classification. Dynamic payloads (variables, substitutions) cannot be proven
// statically and stay out of scope by the agent-mistake threat model.
function shellCommandPayload(position) {
  if (!position.command) return null;
  if (!["sh", "bash", "zsh"].includes(basename(position.command.value))) return null;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) continue;
    let payloadIndex = i + 1;
    if (words[payloadIndex]?.value === "--") payloadIndex += 1;
    const payload = words[payloadIndex];
    if (payload && payload.literal && payload.subs.length === 0) return payload.value;
    return null;
  }
  return null;
}

function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

const UNSUPPORTED_KEYWORDS = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac",
  "do", "done", "function", "time", "coproc",
]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// Recursive program analysis. Returns:
//   broadKill      an executed broad kill was proven somewhere in the program
//   unscopedPgrep  the program executes a pgrep not scoped to the worktree
//                  (its output is a machine-wide PID list)
//   unsupported    grammar this classifier does not model was seen
//   error          the lexer could not tokenize the program
function analyzeProgram(command, worktree, taintedVars, depth = 0) {
  if (depth > 12) {
    return { broadKill: rawMentionsNameKill(command), unscopedPgrep: false, unsupported: true, error: "recursion limit" };
  }
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    return { broadKill: false, unscopedPgrep: false, unsupported: true, error: lexed.error };
  }
  const { nodes, separators } = splitProgram(lexed.tokens);
  let broadKill = false;
  let unscopedPgrep = false;
  let unsupported = false;
  // Assignment taint: NAME=$(pgrep -f dev) marks NAME, so a later `kill $NAME`
  // is recognized as consuming pattern-matched PIDs. A clean reassignment
  // clears the taint, mirroring the arm policy's variable tracking.
  const tainted = new Set(taintedVars || []);
  // Pipeline taint: an unscoped pgrep stage flows into later stages of the
  // same pipeline, so `pgrep -f dev | xargs kill` is recognized.
  let pipeCarriesPgrep = false;

  for (let index = 0; index < nodes.length; index += 1) {
    const tokens = nodes[index];
    const position = commandPosition(tokens);
    if (UNSUPPORTED_KEYWORDS.has(basename(position.words[0]?.value || ""))) unsupported = true;
    if (position.unresolvedWrapperOption) unsupported = true;

    // Recurse into subshell/brace groups and command/process substitutions.
    const substitutionResults = new Map();
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = analyzeProgram(token.content, worktree, tainted, depth + 1);
        broadKill ||= nested.broadKill;
        unscopedPgrep ||= nested.unscopedPgrep;
        if ((nested.error || nested.unsupported) && rawMentionsNameKill(token.content)) unsupported = true;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = analyzeProgram(substitution.content, worktree, tainted, depth + 1);
          substitutionResults.set(substitution, nested);
          broadKill ||= nested.broadKill;
          if ((nested.error || nested.unsupported) && rawMentionsNameKill(substitution.content)) unsupported = true;
        }
      }
    }

    // Record assignment taint from this node's words.
    for (const word of position.words) {
      const name = assignmentName(word);
      if (!name || !isAssignment(word.value)) continue;
      const taints = word.subs.some((substitution) => substitutionResults.get(substitution)?.unscopedPgrep);
      if (taints || wordReferencesAny(word, tainted)) tainted.add(name);
      else tainted.delete(name);
    }

    const commandName = basename(position.command?.value || "");
    const args = position.words.slice(position.index + 1);
    const scoped = args.some((word) => wordIsScoped(word, worktree));

    if (NAME_KILLS.has(commandName) && !scoped) broadKill = true;

    if (commandName === "pgrep" && !scoped) unscopedPgrep = true;

    if (commandName === "kill") {
      const consumesPgrep = args.some(
        (word) =>
          word.subs.some((substitution) => substitutionResults.get(substitution)?.unscopedPgrep) ||
          wordReferencesAny(word, tainted),
      );
      if (consumesPgrep) broadKill = true;
    }

    // `... | xargs kill` (or xargs -0/-n1/-I{} kill): the kill verb is an
    // argument of xargs, fed by whatever the pipe carries.
    if (commandName === "xargs" && pipeCarriesPgrep) {
      if (args.some((word) => ["kill", "pkill", "killall"].includes(basename(word.value)))) broadKill = true;
    }

    // Literal nested shell and eval payloads are recursively classified.
    for (const payload of [shellCommandPayload(position), evalPayload(position)]) {
      if (payload === null) continue;
      const nested = analyzeProgram(payload, worktree, tainted, depth + 1);
      broadKill ||= nested.broadKill;
      unscopedPgrep ||= nested.unscopedPgrep;
      if ((nested.error || nested.unsupported) && rawMentionsNameKill(payload)) unsupported = true;
    }

    // Propagate pipeline taint to the next stage.
    if (isPipe(separators[index])) {
      pipeCarriesPgrep = pipeCarriesPgrep || (commandName === "pgrep" && !scoped);
    } else {
      pipeCarriesPgrep = false;
    }
  }

  return { broadKill, unscopedPgrep, unsupported, error: "" };
}

function deny(code, worktree) {
  return { decision: "deny", code, reason: reasons(worktree)[code] };
}

function decision(command, worktree) {
  const normalizedWorktree = worktree ? path.normalize(worktree).replace(/\/+$/, "") : "";
  // Without a worktree identity there is nothing to scope against; the
  // transport never calls this without one, and failing open here keeps a
  // misconfigured hook from denying every shell command.
  if (!normalizedWorktree) return { decision: "allow" };
  const analysis = analyzeProgram(command, normalizedWorktree, new Set());
  if (analysis.broadKill) return deny("broad-kill", normalizedWorktree);
  if ((analysis.error || analysis.unsupported) && rawMentionsNameKill(command)) {
    return deny("unclassifiable-kill", normalizedWorktree);
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, worktree: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--worktree") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      if (name === "--command") result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name.startsWith("--worktree=")) {
      result.worktree = name.slice("--worktree=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.worktree);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
