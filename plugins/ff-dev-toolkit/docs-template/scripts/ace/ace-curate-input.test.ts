import { describe, expect, it } from 'vitest';
import { parseCurateInput } from './ace-curate-input';
describe('curate source routing', () => {
  it('keeps latest PR and explicit PR compatibility', () => {
    expect(parseCurateInput([]).mode).toBe('latest-pr');
    expect(parseCurateInput(['123'])).toEqual({ mode:'pr', pr:'123', issue:null, sources:[] });
  });
  it('requires Issue for sources-only and preserves literal source tokens', () => {
    expect(parseCurateInput(['--issue','44','--source','meeting notes.md','--source','https://example.test/a?q=x&b=y','--source','$(touch /tmp/no)']).mode).toBe('sources');
    expect(parseCurateInput(['--issue','44','--source','meeting notes.md']).sources).toEqual(['meeting notes.md']);
    expect(() => parseCurateInput(['--source','memo.md'])).toThrow('requires --issue');
  });
  it('PR takes origin precedence over a related Issue', () => {
    expect(parseCurateInput(['123','--source','memo.md','--issue','44'])).toMatchObject({mode:'pr',pr:'123',issue:'44'});
  });
  it.each([['0'],['-1'],['--unknown'],['--source'],['--issue','x'],['--issue','44'],['--issue','1','--issue','2'],['1','2'],['--source','--issue'],['--source',' ']])('rejects invalid argv %j before reads or writes', (...argv) => {
    expect(() => parseCurateInput(argv)).toThrow();
  });
});
