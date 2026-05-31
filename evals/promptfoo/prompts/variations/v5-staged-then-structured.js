/**
 * Promptfoo prompt module for Variation 5 (Staged Reasoning → Structured Spec).
 *
 * The model performs full V2-style internal staging as thinking space,
 * then emits a single clean structured JSON spec for DotSerializer.
 */

const fs = require('fs');
const path = require('path');

const baseSystemPath = path.join(__dirname, '../skill-to-dot-system.txt');
const baseSystem = fs.readFileSync(baseSystemPath, 'utf8');

const variationPath = path.join(__dirname, 'v5-staged-then-structured.md');
const variationInstructions = fs.readFileSync(variationPath, 'utf8');

const systemPrompt = baseSystem + "\n\n" + variationInstructions;

module.exports = function ({ vars }) {
  const skillName = vars.skill_name || 'unnamed-skill';
  const skillBody = vars.skill_body || '';

  return [
    {
      role: 'system',
      content: systemPrompt
    },
    {
      role: 'user',
      content: `Design a high-quality structured pipeline spec (JSON) for this skill using the full staged reasoning process described in the system instructions.

Skill name: ${skillName}

${skillBody}

Perform the three internal stages thoroughly. When you are completely finished with all internal reasoning, output exactly one top-level JSON object matching the spec shape in the system instructions. Nothing else.`
    }
  ];
};
