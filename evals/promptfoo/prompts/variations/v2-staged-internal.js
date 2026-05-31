/**
 * Promptfoo prompt module for Variation 2 (Staged Internal Thinking).
 * 
 * Combines:
 * - The authoritative base system prompt (from CompilationPrompt)
 * - The variation-specific instructions
 * - The standard user message that actually delivers the SKILL.md content
 */

const fs = require('fs');
const path = require('path');

const baseSystemPath = path.join(__dirname, '../skill-to-dot-system.txt');
const baseSystem = fs.readFileSync(baseSystemPath, 'utf8');

const variationPath = path.join(__dirname, 'v2-staged-internal.md');
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
      content: `Compile this skill to a DOT graph:

Skill name: ${skillName}

${skillBody}`
    }
  ];
};
