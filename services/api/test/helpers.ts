import assert from 'node:assert/strict';

type Api = (method: 'POST', url: string, payload?: object) => Promise<{ statusCode: number; json: () => { code: string; id: string; token: string } }>;

/** Pairs a worker as the app and `connect` do: a code for the signed-in user, then the public pair call. */
export async function pairWorker(api: Api, name = 'My Mac') {
  const { code } = (await api('POST', '/workers/pairing')).json();
  const res = await api('POST', '/workers/pair', { code, name });
  assert.equal(res.statusCode, 201);
  return res.json();
}
