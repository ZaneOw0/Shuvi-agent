'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const h = require('./unified-host-entry.cjs').harness();
const { ParsedDocumentView } = h.load('ui/ParsedDocumentView');
const { ParsedDocumentRecord } = h.load('domain/ParsedDocumentModels');
const { UnifiedProcessingJob } = h.load('domain/UnifiedKnowledgeModels');

function setup(states) {
  const view = new ParsedDocumentView();
  view.documents = [Object.assign(new ParsedDocumentRecord(), { id: 'doc', activeGeneration: 'v1', epoch: 2 })];
  view.selectedDocument = 'doc';
  view.processingJobs = states.map((state, index) => Object.assign(new UnifiedProcessingJob(), {
    id: `job-${String(index).padStart(2, '0')}`, documentKey: 'doc', version: 'v1', epoch: 2,
    stage: index === 0 ? 'BodyEmbedding' : 'ImageEmbedding', state, completed: 1, expected: 2
  }));
  return view;
}

test('processing status: fixed pages cover all jobs without expanding the full array', () => {
  const view = setup(Array(12).fill('Complete'));
  view.processingExpanded = true;
  assert.equal(view.processingPageCount(), 3);
  assert.equal(view.selectedJobs().length, 5);
  const seen = view.selectedJobs().map(job => job.id);
  view.changeProcessingPage(1); seen.push(...view.selectedJobs().map(job => job.id));
  view.changeProcessingPage(1); seen.push(...view.selectedJobs().map(job => job.id));
  assert.equal(view.selectedJobs().length, 2);
  assert.equal(new Set(seen).size, 12);
  view.changeProcessingPage(1); assert.equal(view.processingPage, 2);
  view.processingJobs = view.processingJobs.slice(0, 2);
  assert.equal(view.selectedJobs().length, 2);
  view.changeProcessingPage(-1); assert.equal(view.processingPage, 0);
});

test('processing status: collapsed preview remains limited to three unfinished jobs', () => {
  const view = setup(['Complete', 'Failed', 'Unknown', 'Paused', 'Pending']);
  assert.equal(view.selectedJobs().length, 3);
  assert(view.selectedJobs().every(job => job.state !== 'Complete'));
});

test('processing status: batch retries every page of current-version jobs and starts the queue', async () => {
  const view = setup(['Failed', 'Complete', 'Unknown', 'Paused', 'Running', 'Failed', 'AwaitingConfig', 'Pending']);
  const extra = [{ documentKey: 'other' }, { version: 'old' }, { epoch: 1 }].map((patch, i) =>
    Object.assign(new UnifiedProcessingJob(), view.processingJobs[0], patch, { id: 'excluded-' + i }));
  const jobs = view.processingJobs.concat(extra);
  const retried = []; let kicks = 0;
  view.queue = { jobs: async () => jobs, retry: async (id, cost) => { assert.equal(cost, true); retried.push(id); }, kick: () => kicks++ };
  view.refreshResources = async () => {};
  view.retryAllConfirm = true;
  await view.retryUnfinishedProcessing();
  assert.deepEqual(retried, ['job-00', 'job-02', 'job-03', 'job-05']);
  assert.equal(kicks, 1);
  assert.equal(view.processingJobs[0].completed, 1, 'retain partial success');
  assert.equal(view.processingBusy, false); assert.equal(view.retryAllConfirm, false);
  assert.equal(h.requests(), 0);
});

test('processing status: batch continues after one enqueue failure and reports it', async () => {
  const view = setup(['Failed', 'Unknown', 'Paused']);
  const retried = []; let kicks = 0;
  view.queue = { jobs: async () => view.processingJobs, retry: async id => { retried.push(id); if (id === 'job-01') throw Error('enqueue'); }, kick: () => kicks++ };
  view.refreshResources = async () => {};
  view.retryAllConfirm = true;
  await view.retryUnfinishedProcessing();
  assert.equal(retried.length, 3); assert.equal(kicks, 1);
  assert.match(view.message, /2 项已重新排队，1 项未能排队/);
  assert.equal(view.processingBusy, false);
});

test('processing status: no confirmation or busy state does not dispatch', async () => {
  const view = setup(['Failed']);
  view.queue = { jobs: async () => { throw Error('must not dispatch'); } };
  await view.retryUnfinishedProcessing();
  view.retryAllConfirm = true; view.processingBusy = true;
  await view.retryUnfinishedProcessing();
});

test('processing status: waiting jobs trigger scheduling without retrying completed or running jobs', async () => {
  const view = setup(['Pending', 'AwaitingConfig', 'Complete', 'Running', 'Canceled']);
  assert.equal(view.selectedUnfinishedCount(), 2);
  let kicks = 0;
  view.queue = { jobs: async () => view.processingJobs, retry: async () => { throw Error('must not retry'); }, kick: () => kicks++ };
  view.refreshResources = async () => {};
  view.retryAllConfirm = true;
  await view.retryUnfinishedProcessing();
  assert.equal(kicks, 1);
});
