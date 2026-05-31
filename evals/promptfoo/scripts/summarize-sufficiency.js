#!/usr/bin/env node
/**
 * summarize-sufficiency.js
 *
 * Consumes a promptfoo results JSON (from `promptfoo eval -o results.json`)
 * and emits a concise "model sufficiency for Arbor orchestrator" verdict.
 *
 * Usage:
 *   node evals/promptfoo/scripts/summarize-sufficiency.js results.json > verdict.md
 *
 * It looks for the structural similarity + validate assertions we defined
 * and applies the bar described in the README.
 */

const fs = require('fs');

const file = process.argv[2];
if (!file) {
  console.error('Usage: node summarize-sufficiency.js <promptfoo-results.json>');
  process.exit(1);
}

const results = JSON.parse(fs.readFileSync(file, 'utf8'));

// promptfoo results shape (v0.XX): results.results[].gradingResult, etc.
const tests = results.results || results.tests || [];

const byModel = {};

for (const t of tests) {
  const provider = t.provider?.id || t.provider || 'unknown';
  const model = (t.vars && t.vars.model) || provider.split(':').pop() || 'unknown';
  if (!byModel[model]) byModel[model] = { passes: 0, total: 0, scores: [], details: [] };

  byModel[model].total++;

  const gr = t.gradingResult || t.grading || {};
  const passed = gr.pass === true || gr.passed === true;
  if (passed) byModel[model].passes++;

  // Try to pull our structural score if present
  const score = gr.score != null ? gr.score : (gr.componentResults || []).reduce((s, c) => s + (c.score || 0), 0) / Math.max(1, (gr.componentResults || []).length);
  byModel[model].scores.push(score || 0);

  const reason = gr.reason || (t.assertionResults && t.assertionResults.map(a => a.reason).join('; ')) || '';
  if (!passed || score < 0.7) {
    byModel[model].details.push({ id: t.description || t.vars?.skill_name || 'unknown', passed, score, reason: reason.slice(0, 200) });
  }
}

console.log('# Arbor Skill-to-DOT Model Sufficiency Report\n');
console.log(`Generated: ${new Date().toISOString()}\n`);

for (const [model, data] of Object.entries(byModel)) {
  const avg = data.scores.reduce((a, b) => a + b, 0) / data.scores.length;
  const rate = data.passes / data.total;
  const verdict = (rate === 1 && avg >= 0.78) ? '**READY**' :
                  (rate >= 0.8 && avg >= 0.65) ? '**USABLE (review COMPILED.dot)**' :
                  '**NOT YET**';

  console.log(`## ${model}`);
  console.log(`- Pass rate: ${(rate * 100).toFixed(0)}% (${data.passes}/${data.total})`);
  console.log(`- Avg structural score: ${avg.toFixed(3)}`);
  console.log(`- Verdict: ${verdict}\n`);

  if (data.details.length > 0) {
    console.log('### Problem cases');
    for (const d of data.details) {
      console.log(`- ${d.id}: ${d.passed ? 'passed' : 'FAILED'} (score ${d.score.toFixed(2)}) — ${d.reason}`);
    }
    console.log('');
  }
}

console.log('---');
console.log('Bar used: 100% validate pass + avg structural ≥ 0.78 + no critical rubric failures.');
console.log('See evals/promptfoo/README.md for exact criteria and how to iterate.');
