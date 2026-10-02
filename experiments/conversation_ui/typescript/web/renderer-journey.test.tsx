import test from 'node:test';
import assert from 'node:assert/strict';
import { createConversationStore } from '../shared/store.mjs';
import { createFixtureTransport } from '../shared/fixture.mjs';
import { exerciseRealSurfaces } from './real-surfaces.js';

test('joined renderer helper confirms through web, submits Unicode through Ink, and clears both active surfaces',
  { timeout: 30_000 }, async () => {
    const transport = createFixtureTransport({ includeQuestion: true });
    const store = createConversationStore({ caller: 'human_comparison', target: 'agent_comparison', transport });
    let surfaces: Awaited<ReturnType<typeof exerciseRealSurfaces>> | undefined;
    try {
      assert.equal((await store.sync()).ok, true);
      surfaces = await exerciseRealSurfaces(store);
      assert.deepEqual(surfaces.claims, ['actual_web_question_controls', 'actual_ink_unicode_composer',
        'ink_observes_host_question_completion', 'web_observes_host_ink_followup']);
      const ids = store.getSnapshot().messages.map((message) => message.id);
      assert.equal(new Set(ids).size, ids.length);
      assert.equal(store.getSnapshot().messages.filter((message) =>
        message.role === 'user' && message.text === 'Ink follow-up: café 東京 🌿').length, 1);
      const cleared = await surfaces.clearAccessAndClose();
      assert.deepEqual(cleared.claims, ['both_active_surfaces_clear_on_local_access_loss']);
      assert.equal(store.getSnapshot().connection, 'unauthorized');
    } finally {
      await surfaces?.dispose();
      await store.destroy();
    }
  });
