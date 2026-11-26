import { describe, expect, it } from 'vitest';
import { safeToUpdate } from './appupdate';

describe('switching to a new version of the app', () => {
  it('never while the till is open, so a sale being rung up is not lost', () => {
    expect(safeToUpdate('/till')).toBe(false);
    expect(safeToUpdate('/')).toBe(true);
    expect(safeToUpdate('/stock')).toBe(true);
    expect(safeToUpdate('/login')).toBe(true);
  });
});
