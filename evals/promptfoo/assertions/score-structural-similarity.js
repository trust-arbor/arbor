/**
 * score-structural-similarity.js
 * Promptfoo javascript assertion + scoring function.
 *
 * Faithful re-implementation of the key ideas from
 * Arbor.Orchestrator.Eval.Graders.DotDiff (node/edge count sim, handler cosine,
 * keyword Jaccard) using only lightweight regex extraction (because we already
 * ran the real parser in the validate assertion).
 *
 * Returns a rich GradingResult with componentResults so the promptfoo UI
 * shows a breakdown (nodes, edges, handlers, keywords).
 *
 * Config:
 *   config:
 *     expected: "the ground truth DOT string"
 *     weights: { node_count: 0.2, ... }   # optional override
 *     threshold: 0.75
 */

const STOPWORDS = new Set([
  'a', 'an', 'the', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with',
  'is', 'it', 'as', 'by', 'be', 'do', 'if', 'so', 'no', 'not', 'are', 'was', 'has',
  'had', 'will', 'can', 'may', 'this', 'that', 'from', 'each', 'all', 'any', 'its',
  'you', 'your', 'use', 'new', 'file', 'the'
]);

const SHAPE_TO_HANDLER = {
  'Mdiamond': 'start',
  'Msquare': 'exit',
  'box': 'codergen',
  'diamond': 'conditional',
  'hexagon': 'wait.human',
  'parallelogram': 'tool',
  'component': 'parallel',
  'tripleoctagon': 'parallel.fan_in',
  'house': 'stack.manager_loop'
};

module.exports = (output, context) => {
  const cfg = (context && context.config) || {};
  const expected = cfg.expected || (context && context.vars && context.vars.expected_dot);
  const threshold = cfg.threshold != null ? cfg.threshold : 0.6;

  if (!expected) {
    return {
      pass: false,
      score: 0.0,
      reason: 'No expected_dot provided in assertion config or vars.expected_dot'
    };
  }

  const actualDot = (context && context.vars && context.vars._extracted_dot) ||
                    extractFirstDigraph(output) || String(output || '');

  try {
    const actualG = parseLight(actualDot);
    const expectedG = parseLight(expected);

    const nodeSim = countSim(actualG.nodes.length, expectedG.nodes.length);
    const edgeSim = countSim(actualG.edges.length, expectedG.edges.length);
    const handlerSim = handlerCosine(actualG, expectedG);
    const kwSim = keywordJaccard(actualG, expectedG);

    const weights = Object.assign(
      { node_count: 0.20, edge_count: 0.20, handler_dist: 0.30, keyword_coverage: 0.30 },
      cfg.weights || {}
    );

    const score = weights.node_count * nodeSim +
                  weights.edge_count * edgeSim +
                  weights.handler_dist * handlerSim +
                  weights.keyword_coverage * kwSim;

    const passed = score >= threshold;

    const detail = `nodes: ${actualG.nodes.length} vs ${expectedG.nodes.length} (sim ${nodeSim.toFixed(3)}), ` +
                   `edges: ${actualG.edges.length} vs ${expectedG.edges.length} (sim ${edgeSim.toFixed(3)}), ` +
                   `handlers: cosine=${handlerSim.toFixed(3)}, keywords: jaccard=${kwSim.toFixed(3)}`;

    return {
      pass: passed,
      score: Math.max(0, Math.min(1, score)),
      reason: (passed ? 'Structural match ' : 'Structural mismatch ') + detail,
      componentResults: [
        { pass: nodeSim > 0.7, score: nodeSim, reason: `Node count similarity: ${actualG.nodes.length} vs ${expectedG.nodes.length}` },
        { pass: edgeSim > 0.7, score: edgeSim, reason: `Edge count similarity: ${actualG.edges.length} vs ${expectedG.edges.length}` },
        { pass: handlerSim > 0.7, score: handlerSim, reason: `Handler distribution cosine: ${handlerSim.toFixed(3)}` },
        { pass: kwSim > 0.5, score: kwSim, reason: `Prompt/label keyword Jaccard: ${kwSim.toFixed(3)}` }
      ],
      // Extra data for the sufficiency summarizer
      metadata: { nodeSim, edgeSim, handlerSim, kwSim, detail }
    };
  } catch (err) {
    return {
      pass: false,
      score: 0.0,
      reason: `Scoring error: ${err.message}. Check that validate-with-arbor passed first.`
    };
  }
};

// ------------------------------------------------------------------
// Lightweight DOT understanding (no external parser needed)
// ------------------------------------------------------------------

function extractFirstDigraph(text) {
  if (typeof text !== 'string') return '';
  const m = text.match(/digraph\s+\w*\s*\{[\s\S]*$/m);
  return m ? m[0] : '';
}

function parseLight(dotStr) {
  const nodes = [];
  const edges = [];
  const handlerFreq = {};

  // Nodes: id [ label="..." type="llm" shape=... prompt="..." ... ]
  const nodeRe = /(\w+)\s*\[([^\]]*)\]/g;
  let m;
  while ((m = nodeRe.exec(dotStr)) !== null) {
    const id = m[1];
    const attrStr = m[2] || '';
    const attrs = parseAttrs(attrStr);

    const type = attrs.type || attrs.shape || inferFromLabel(attrs.label || id);
    const handler = resolveHandler(type, attrs.shape);

    nodes.push({ id, attrs, handler });
    handlerFreq[handler] = (handlerFreq[handler] || 0) + 1;
  }

  // Edges: A -> B [label="foo" ...] or A -> B
  const edgeRe = /(\w+)\s*->\s*(\w+)(?:\s*\[([^\]]*)\])?/g;
  while ((m = edgeRe.exec(dotStr)) !== null) {
    edges.push({ from: m[1], to: m[2], attrs: parseAttrs(m[3] || '') });
  }

  // Very rough keyword extraction from prompts + labels (same spirit as Elixir)
  const keywords = new Set();
  for (const n of nodes) {
    const text = `${n.attrs.prompt || ''} ${n.attrs.label || ''} ${n.id}`;
    for (const tok of tokenize(text)) {
      if (tok.length >= 3 && !STOPWORDS.has(tok)) keywords.add(tok);
    }
  }

  return { nodes, edges, handlerFreq, keywords: Array.from(keywords) };
}

function parseAttrs(str) {
  const out = {};
  // key="value with spaces" or key=value or key="multi word"
  const re = /(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/g;
  let m;
  while ((m = re.exec(str)) !== null) {
    const k = m[1];
    const v = m[2] || m[3] || m[4] || '';
    out[k] = v.trim();
  }
  return out;
}

function resolveHandler(type, shape) {
  if (type && type !== '""') {
    // Already a semantic type from the model (preferred)
    const t = type.toLowerCase().replace(/"/g, '');
    if (['start', 'exit', 'llm', 'codergen', 'shell', 'conditional', 'tool', 'exec'].includes(t)) return t;
    return t;
  }
  return SHAPE_TO_HANDLER[shape] || 'codergen';
}

function inferFromLabel(label) {
  const l = (label || '').toLowerCase();
  if (l.includes('start')) return 'start';
  if (l.includes('done') || l.includes('exit')) return 'exit';
  if (l.includes('shell') || l.includes('run ') || l.includes('execute')) return 'shell';
  if (l.includes('write') || l.includes('generate') || l.includes('code')) return 'codergen';
  return 'llm';
}

function countSim(a, b) {
  if (a === 0 && b === 0) return 1.0;
  return 1.0 - Math.abs(a - b) / Math.max(a, b, 1);
}

function handlerCosine(actual, expected) {
  const keys = new Set([...Object.keys(actual.handlerFreq), ...Object.keys(expected.handlerFreq)]);
  let dot = 0, ma = 0, mb = 0;
  for (const k of keys) {
    const va = actual.handlerFreq[k] || 0;
    const vb = expected.handlerFreq[k] || 0;
    dot += va * vb;
    ma += va * va;
    mb += vb * vb;
  }
  const m1 = Math.sqrt(ma), m2 = Math.sqrt(mb);
  if (m1 === 0 || m2 === 0) return 0.0;
  return dot / (m1 * m2);
}

function keywordJaccard(actual, expected) {
  const a = new Set(actual.keywords);
  const b = new Set(expected.keywords);
  if (a.size === 0 && b.size === 0) return 1.0;
  let inter = 0;
  for (const k of a) if (b.has(k)) inter++;
  const union = a.size + b.size - inter;
  return union === 0 ? 1.0 : inter / union;
}

function tokenize(text) {
  return String(text)
    .toLowerCase()
    .split(/[\s\p{P}]+/u)
    .filter(Boolean);
}
