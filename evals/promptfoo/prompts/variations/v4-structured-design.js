/**
 * Promptfoo prompt module for Variation 4 (Structured Design + Deterministic Serialization).
 *
 * Model does semantic design work (can use any internal reasoning, including
 * staged thinking) and emits one structured JSON spec.
 * DotSerializer (in the real app) will turn it into valid DOT.
 */

const fs = require('fs');
const path = require('path');

const baseSystemPath = path.join(__dirname, '../skill-to-dot-system.txt');
const baseSystem = fs.readFileSync(baseSystemPath, 'utf8');

const variationPath = path.join(__dirname, 'v4-structured-design.md');
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
      content: `Design a high-quality structured pipeline spec (JSON) for this skill.

Skill name: ${skillName}

${skillBody}

When you are finished reasoning, output exactly one top-level JSON object matching the spec shape described in the system instructions.`
    }
  ];
};
