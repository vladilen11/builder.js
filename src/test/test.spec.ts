import { MoveBuilder } from '../build';
import path from 'path';

describe('test move package', () => {
  const contractDir = 'contract/simple';

  it('test correctly', async () => {
    const builder = new MoveBuilder(path.resolve(__dirname, contractDir), {});
    expect(await builder.test()).toEqual('ok');
  });
});
