/**
 * extract-json.js
 * Promptfoo javascript assertion.
 *
 * Strips markdown fences, <think> blocks, "Thinking:" sections, and extracts
 * the last (or first) top-level JSON object from the model output.
 *
 * Stores the parsed object in context.vars._extracted_spec and the raw
 * JSON string in context.vars._extracted_spec_raw so downstream steps
 * (DotSerializer call) can use it.
 *
 * This is the direct analogue of extract-dot.js for the structured-design arm.
 */

module.exports = (output, context) => {
  if (typeof output !== 'string') {
    output = String(output || '');
  }

  const extracted = extractLastJsonObject(output);

  if (context && context.vars) {
    context.vars._extracted_spec_raw = extracted.raw || null;
    context.vars._extracted_spec = extracted.parsed || null;
  }

  if (extracted.parsed && typeof extracted.parsed === 'object' && !Array.isArray(extracted.parsed)) {
    return {
      pass: true,
      score: 1.0,
      reason: `Extracted valid JSON object with keys: ${Object.keys(extracted.parsed).join(', ')}`,
      componentResults: [
        { pass: true, score: 1.0, reason: 'Well-formed top-level JSON object found after stripping thinking/fences' }
      ]
    };
  }

  return {
    pass: false,
    score: 0.0,
    reason: `No valid top-level JSON object found after extraction. First 200 chars of candidate: ${(extracted.raw || '').slice(0, 200)}`,
    componentResults: [
      { pass: false, score: 0.0, reason: 'Model output did not contain a recognizable JSON object for the structured spec' }
    ]
  };
};

function extractLastJsonObject(text) {
  if (typeof text !== 'string') text = String(text || '');

  // Remove common thinking wrappers
  let cleaned = text
    .replace(/<think>[\s\S]*?<\/think>/gi, '')
    .replace(/^\s*Thinking:.*$/gmi, '')
    .replace(/^\s*Let me (think|reason|analyze|plan).*?(\n\n|\n(?=[A-Z]))/gis, '');

  // Try fenced blocks first (```json, ```javascript, ```, etc.)
  const fenceRe = /```(?:json|javascript|js)?\s*\n?([\s\S]*?)```/gi;
  let match;
  const candidates = [];

  while ((match = fenceRe.exec(cleaned)) !== null) {
    const candidate = match[1].trim();
    const parsed = tryParseJson(candidate);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      candidates.push({ raw: candidate, parsed });
    }
  }

  // If we found good fenced JSON objects, prefer the last one (models often put final answer last)
  if (candidates.length > 0) {
    return candidates[candidates.length - 1];
  }

  // Fallback: balanced-brace scan for the last top-level object
  const lastObj = findLastTopLevelObject(cleaned);
  if (lastObj) {
    const parsed = tryParseJson(lastObj);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return { raw: lastObj, parsed };
    }
  }

  return { raw: null, parsed: null };
}

function tryParseJson(str) {
  try {
    // Be tolerant of trailing commas before } or ]
    const tolerant = str.replace(/,\s*([}\]])/g, '$1');
    return JSON.parse(tolerant);
  } catch {
    return null;
  }
}

function findLastTopLevelObject(text) {
  let lastStart = -1;
  let depth = 0;
  let inString = false;
  let escape = false;
  let startIdx = -1;

  for (let i = 0; i < text.length; i++) {
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

    if (ch === '{') {
      if (depth === 0) startIdx = i;
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0 && startIdx !== -1) {
        lastStart = startIdx;
        startIdx = -1;
      }
    }
  }

  if (lastStart === -1) return null;

  // Re-scan from lastStart to find the matching close
  depth = 0;
  inString = false;
  escape = false;

  for (let i = lastStart; i < text.length; i++) {
    const ch = text[i];
    if (escape) { escape = false; continue; }
    if (ch === '\\') { escape = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;

    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        return text.slice(lastStart, i + 1).trim();
      }
    }
  }

  return null;
}
