export const PSEUDO_EMBED_DIM: number = 64;
export const PSEUDO_EMBED_SPACE: string = 'pseudo:hash:v1:64';

// 仅用于机制验证的确定性伪向量：可验证向量列、距离查询与双路融合是否跑通，
// 不具备语义能力，不得据此得出任何检索质量结论。
export function pseudoEmbedding(text: string): Float32Array {
  const vector: Float32Array = new Float32Array(PSEUDO_EMBED_DIM);
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    const slot: number = code % PSEUDO_EMBED_DIM;
    vector[slot] = vector[slot] + 1;
    const next: number = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
    const pair: number = (code * 31 + next) % PSEUDO_EMBED_DIM;
    vector[pair] = vector[pair] + 0.5;
  }
  return normalize(vector);
}

export function cosineDistance(left: Float32Array, right: Float32Array): number {
  const size: number = Math.min(left.length, right.length);
  let dot: number = 0;
  for (let i = 0; i < size; i++) {
    dot = dot + left[i] * right[i];
  }
  return 1 - dot;
}

function normalize(vector: Float32Array): Float32Array {
  let sum: number = 0;
  for (let i = 0; i < vector.length; i++) {
    sum = sum + vector[i] * vector[i];
  }
  const length: number = Math.sqrt(sum);
  if (length === 0) {
    return vector;
  }
  for (let i = 0; i < vector.length; i++) {
    vector[i] = vector[i] / length;
  }
  return vector;
}
