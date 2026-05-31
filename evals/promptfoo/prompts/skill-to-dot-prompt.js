/**
 * Promptfoo-compatible prompt module.
 * Returns a chat conversation (system + user) using the authoritative
 * system prompt we dump from the Elixir CompilationPrompt module.
 *
 * This makes the config portable across promptfoo versions.
 */

const fs = require('fs');
const path = require('path');

const systemPath = path.join(__dirname, 'skill-to-dot-system.txt');
const systemPrompt = fs.readFileSync(systemPath, 'utf8');

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
