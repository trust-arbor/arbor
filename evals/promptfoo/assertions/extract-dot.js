/**
 * extract-dot.js
 * Promptfoo javascript assertion.
 *
 * Strips markdown fences, <think> blocks, and extracts the first valid-looking
 * digraph {...} block. Returns the cleaned DOT string or the original if nothing
 * looks like DOT.
 *
 * Used as a pre-step by other assertions and by the UI.
 *
 * Usage in promptfooconfig.yaml:
 *   - type: javascript
 *     value: file://../assertions/extract-dot.js
 */

module.exports = (output, context) => {
  if (typeof output !== 'string') {
    output = String(output || '');
  }

  const extracted = extractDot(output);

  // Store the cleaned version so downstream assertions (validate, score) can read it
  // via context.vars or by re-extracting (we prefer re-extract for purity).
  if (context && context.vars) {
    context.vars._extracted_dot = extracted;
  }

  const hasDigraph = /digraph\s+\w+/i.test(extracted);
  const len = extracted.trim().length;

  if (hasDigraph && len > 20) {
    return {
      pass: true,
      score: 1.0,
      reason: `Extracted ${len} chars of DOT (starts with digraph)`,
      componentResults: [
        { pass: true, score: 1.0, reason: 'DOT content detected after stripping fences/think blocks' }
      ]
    };
  }

  return {
    pass: false,
    score: 0.0,
    reason: `No valid digraph found after extraction (len=${len}). First 120 chars: ${extracted.slice(0, 120)}`,
    componentResults: [
      { pass: false, score: 0.0, reason: 'Model output did not contain a recognizable DOT graph' }
    ]
  };
};

function extractDot(text) {
  if (typeof text !== 'string') text = String(text || '');

  // Remove common thinking blocks (DeepSeek, Qwen, etc.)
  let cleaned = text.replace(/<think>[\s\S]*?<\/think>/gi, '');

  // Try fenced code block first (```dot, ```graphviz, or plain ```)
  const fenceMatch = cleaned.match(/```(?:dot|graphviz)?\s*\n?([\s\S]*?)```/i);
  if (fenceMatch && fenceMatch[1]) {
    const candidate = fenceMatch[1].trim();
    if (/digraph/i.test(candidate)) return candidate;
  }

  // Bare digraph with balanced braces (handles most LLM outputs)
  const bare = extractFirstBalancedDigraph(cleaned);
  if (bare) return bare;

  // Last resort: return the original text (downstream will fail validation)
  return cleaned.trim();
}

function extractFirstBalancedDigraph(text) {
  const startMatch = text.match(/digraph\s+\w*\s*\{/i);
  if (!startMatch) return null;

  const startIdx = startMatch.index;
  let depth = 0;
  let inString = false;
  let escape = false;

  for (let i = startIdx; i < text.length; i++) {
    const ch = text[i];

    if (escape) {
      escape = false;
      continue;
    }
    if (ch === '\\') {
      escape = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;

    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        return text.slice(startIdx, i + 1).trim();
      }
    }
  }
  // Unbalanced — return what we have (validation will catch it)
  return text.slice(startIdx).trim();
}
