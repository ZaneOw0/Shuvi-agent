"""Offline official host references. Only public R017 artifacts and synthetic fixtures."""
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
CACHE = ROOT / '.cache/r017-tokenizer'
sys.path.insert(0, str(CACHE / 'oracle'))
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
import tokenizers
import sentencepiece

fast = tokenizers.Tokenizer.from_file(str(CACHE / 'tokenizer.json'))
slow = sentencepiece.SentencePieceProcessor(model_file=str(CACHE / 'sentencepiece.bpe.model'))
assert fast.truncation is None and fast.padding is None
golden = json.loads((ROOT / 'entry/src/test/r017/golden-inputs.json').read_text())
rows = []
for case in golden['cases']:
    text = case['text'] * case.get('repeat', 1)
    encoded = fast.encode(text)
    normal = fast.normalizer.normalize_str(text)
    slow_normal = slow.normalize(text)
    rows.append({
        'id': case['id'], 'textHash': hashlib.sha256(text.encode('utf-8')).hexdigest(),
        'fastCount': len(encoded.ids), 'fastIdsSha256': hashlib.sha256(json.dumps(encoded.ids, separators=(',', ':')).encode()).hexdigest(),
        'fastNormalizedScalars': len(normal), 'slowRawCountPlus2': len(slow.encode(text)) + 2,
        'slowNormalizedScalars': len(slow_normal)
    })

# Independently exercise all charsmap rules with Google's normalizer, not the Node derivation.
rules = json.loads((CACHE / 'charsmap-rules.json').read_text())
ranges = json.loads((CACHE / 'derived-profile.json').read_text())['derivation']['ranges']
weights = {}
for first, last, weight in ranges:
    for scalar in range(first, last + 1):
        weights[scalar] = weight
max_slack = 0
for source, target in rules:
    bound = sum(weights.get(ord(c), 1) for c in source) + 1
    # Pure SentencePiece path, including its single dummy prefix.
    size = len(slow.normalize(source))
    assert size <= bound, 'SentencePiece normalizer rule coverage'
    assert len(fast.normalizer.normalize_str(source)) <= bound - 1, 'HF normalizer rule coverage'
    max_slack = max(max_slack, bound - size)

# Deterministic combinations include cross-scalar rules, deletions, literals and graphemes.
alphabet = ['a', '中', ' ', '\t', '\u200b', '\u00a0', '\u0301', 'ﬃ', 'ﷺ', '😀', '<s>', '<mask>', '＜ｍａｓｋ＞']
seed = 17017
combinations = []
for index in range(2000):
    text = ''
    for count in range(1 + index % 31):
        seed = (seed * 1664525 + 1013904223) & 0xffffffff
        text += alphabet[seed % len(alphabet)]
    # Broad independently computed W+L+3 bound (at most L+1 ordinary fragments).
    weight = sum(weights.get(ord(c), 1) for c in text)
    literal_count = sum(text.count(s) for s in ['<s>', '<pad>', '</s>', '<unk>', '<mask>'])
    bound = weight + 2 * literal_count + 3
    assert len(fast.encode(text).ids) <= bound, 'HF combined reference coverage'
    assert len(slow.encode(text)) + 2 <= weight + 3, 'SP combined reference coverage'
    combinations.append({'text': text, 'count': len(fast.encode(text).ids)})

result = {'schema': 'R017-OFFICIAL-HOST-REFERENCE-1', 'tokenizers': tokenizers.__version__,
          'sentencepiece': sentencepiece.__version__, 'modelRevision': 'a46a13810c9d7f876fccd8d7017512ebc265d2c1',
          'normalizerRuleCases': len(rules), 'combinedCases': 2000, 'maxNormalizerSlack': max_slack, 'golden': rows}
(CACHE / 'oracle-results.json').write_text(json.dumps(result, ensure_ascii=True, indent=2) + '\n')
(CACHE / 'oracle-combinations.json').write_text(json.dumps(combinations, ensure_ascii=True) + '\n')
print('REFERENCE_PASS cases=%d rules=%d combinations=2000 fast=%s slow=%s' %
      (len(rows), len(rules), tokenizers.__version__, sentencepiece.__version__))
