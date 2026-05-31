/**
 * serialize-with-arbor.js
 * Promptfoo javascript assertion.
 *
 * Takes the structured spec extracted by extract-json.js (_extracted_spec),
 * feeds it to Arbor.Actions.Skill.DotSerializer.compile/1 (real Elixir code),
 * and produces a DOT string.
 *
 * Stores the resulting DOT in context.vars._extracted_dot (and _extracted_dot_raw)
 * so the downstream validate-with-arbor + structural + judge pipeline can run
 * completely unchanged.
 *
 * This is the bridge that lets the "structured design" eval arm get 100%
 * syntactic validity by construction while still using the exact same judge.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

module.exports = (output, context) => {
  const spec = (context && context.vars && context.vars._extracted_spec) || null;

  if (!spec || typeof spec !== 'object' || Array.isArray(spec)) {
    return {
      pass: false,
      score: 0.0,
      reason: 'No valid structured spec available from extract-json.js (expected object)'
    };
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'promptfoo-arbor-json-'));
  const specFile = path.join(tmpDir, 'spec.json');
  const dotFile = path.join(tmpDir, 'generated.dot');

  try {
    fs.writeFileSync(specFile, JSON.stringify(spec, null, 2), 'utf8');

    // Call the real DotSerializer via mix.
    // Success: prints DOT_START\n<dot>\nDOT_END
    // Failure: prints SERIALIZER_ERROR and exits non-zero.
    const elixirExpr = `
      spec = Jason.decode!(File.read!("${specFile}"))
      case Arbor.Actions.Skill.DotSerializer.compile(spec) do
        {:ok, dot} ->
          IO.puts("DOT_START")
          IO.write(dot)
          IO.puts("DOT_END")
          System.halt(0)
        {:error, reason} ->
          IO.puts("SERIALIZER_ERROR: " <> inspect(reason))
          System.halt(1)
      end
    `;

    let stdout;
    try {
      stdout = execSync(`mix run --no-start -e '${elixirExpr}'`, {
        cwd: process.cwd(),
        encoding: 'utf8',
        timeout: 60000,
        stdio: ['pipe', 'pipe', 'pipe']
      });
    } catch (err) {
      const out = (err.stdout || '') + (err.stderr || err.message || '');
      return {
        pass: false,
        score: 0.0,
        reason: `DotSerializer rejected the spec:\n${out.slice(0, 800)}`
      };
    }

    if (/SERIALIZER_ERROR/.test(stdout)) {
      return {
        pass: false,
        score: 0.0,
        reason: `DotSerializer failed on the spec:\n${stdout.slice(0, 800)}`
      };
    }

    // Extract the DOT from the marked block
    const dotMatch = stdout.match(/DOT_START\n([\s\S]*?)DOT_END/);
    let dot;
    if (dotMatch && dotMatch[1]) {
      dot = dotMatch[1];
    } else {
      // Fallback: read from the file we wrote (if the script wrote it)
      try {
        dot = fs.readFileSync(dotFile, 'utf8');
      } catch (_) {
        return {
          pass: false,
          score: 0.0,
          reason: `Could not extract DOT from serializer output. Stdout tail: ${stdout.slice(-600)}`
        };
      }
    }

    if (context && context.vars) {
      context.vars._extracted_dot = dot;
      context.vars._extracted_dot_raw = dot;
    }

    return {
      pass: true,
      score: 1.0,
      reason: 'Structured spec successfully serialized to valid DOT via DotSerializer',
      componentResults: [
        { pass: true, score: 1.0, reason: 'DotSerializer.compile/1 produced DOT without error' }
      ]
    };

  } catch (e) {
    return {
      pass: false,
      score: 0.0,
      reason: `Error during serialization step: ${e.message}`
    };
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) {}
  }
};
