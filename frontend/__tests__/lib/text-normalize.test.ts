import { normalizeBlocks } from '@/lib/text-normalize';

function blockText(block: ReturnType<typeof normalizeBlocks>[number]): string {
  if ('text' in block) return block.text;
  throw new Error('Expected text block');
}


describe('空输入', () => {
  it('空字符串 → 空数组', () => {
    expect(normalizeBlocks('')).toEqual([]);
  });

  it('全空白字符串 → 空数组', () => {
    expect(normalizeBlocks('  \n  \n  ')).toEqual([]);
  });
});


describe('单段落', () => {
  it('没有换行的文本 → 一个 paragraph 块', () => {
    const text = 'The cat sat on the mat and looked around carefully.';
    const blocks = normalizeBlocks(text);
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({ type: 'paragraph', text });
  });
});


describe('双换行模式（\\n\\n 分段）', () => {
  it('双换行 → 分成两个块', () => {
    const blocks = normalizeBlocks('First paragraph.\n\nSecond paragraph.');
    expect(blocks).toHaveLength(2);
    expect(blockText(blocks[0])).toBe('First paragraph.');
    expect(blockText(blocks[1])).toBe('Second paragraph.');
  });

  it('段落内的单换行合并为空格（消除 PDF 硬换行）', () => {
    const blocks = normalizeBlocks('Line one\nline two\n\nNew paragraph.');
    expect(blockText(blocks[0])).toBe('Line one line two');
    expect(blockText(blocks[1])).toBe('New paragraph.');
  });

  it('多个连续空行等同于双换行', () => {
    const blocks = normalizeBlocks('Para one.\n\n\n\nPara two.');
    expect(blocks).toHaveLength(2);
  });

  it('段落首尾空白被裁剪', () => {
    const blocks = normalizeBlocks('  First paragraph.  \n\n  Second paragraph.  ');
    expect(blockText(blocks[0])).toBe('First paragraph.');
    expect(blockText(blocks[1])).toBe('Second paragraph.');
  });
});


describe('单换行模式（无双换行时的兜底）', () => {
  it('没有双换行时按单换行分块', () => {
    const blocks = normalizeBlocks('Line one\nLine two\nLine three');
    expect(blocks).toHaveLength(3);
    expect(blockText(blocks[0])).toBe('Line one');
    expect(blockText(blocks[1])).toBe('Line two');
    expect(blockText(blocks[2])).toBe('Line three');
  });

  it('单换行模式中空行被跳过', () => {
    const blocks = normalizeBlocks('Line one\n\nLine two');

    expect(blocks).toHaveLength(2);
  });
});


describe('标题检测', () => {
  it('全大写短行 → heading1', () => {
    const blocks = normalizeBlocks('CHAPTER ONE\n\nSome paragraph text here.');
    expect(blocks[0].type).toBe('heading1');
    expect(blocks[1].type).toBe('paragraph');
  });

  it('全大写但超过 80 字符 → paragraph（不是标题）', () => {
    const long = 'THIS IS A VERY LONG LINE THAT GOES ON AND ON AND ON AND IS DEFINITELY NOT A HEADING';
    const blocks = normalizeBlocks(long);
    expect(blocks[0].type).toBe('paragraph');
  });

  it('"Chapter N" 前缀 → heading1（大小写不敏感）', () => {
    expect(normalizeBlocks('Chapter 1: The Beginning\n\nSome text.')[0].type).toBe('heading1');
    expect(normalizeBlocks('CHAPTER TWO\n\nSome text.')[0].type).toBe('heading1');
    expect(normalizeBlocks('chapter three\n\nSome text.')[0].type).toBe('heading1');
  });

  it('"Part" 前缀 → heading1', () => {
    expect(normalizeBlocks('Part One\n\nSome text.')[0].type).toBe('heading1');
    expect(normalizeBlocks('PART III\n\nSome text.')[0].type).toBe('heading1');
  });

  it('"Prologue" / "Epilogue" → heading1', () => {
    expect(normalizeBlocks('Prologue\n\nText.')[0].type).toBe('heading1');
    expect(normalizeBlocks('Epilogue\n\nText.')[0].type).toBe('heading1');
  });

  it('罗马数字 → heading1', () => {
    expect(normalizeBlocks('IV.\n\nText.')[0].type).toBe('heading1');
    expect(normalizeBlocks('XII\n\nText.')[0].type).toBe('heading1');
    expect(normalizeBlocks('I.\n\nText.')[0].type).toBe('heading1');
  });

  it('短行且无句末标点 → paragraph（不再猜测为 heading2）', () => {
    expect(normalizeBlocks('The Final Chapter')[0].type).toBe('paragraph');
    expect(normalizeBlocks('Into the Dark')[0].type).toBe('paragraph');
  });

  it('短行以句号结尾 → paragraph（不是标题）', () => {
    expect(normalizeBlocks('He was tired.')[0].type).toBe('paragraph');
  });

  it('短行以逗号结尾 → paragraph', () => {
    expect(normalizeBlocks('He said,')[0].type).toBe('paragraph');
  });

  it('短行以问号结尾 → paragraph', () => {
    expect(normalizeBlocks('Who are you?')[0].type).toBe('paragraph');
  });

  it('超过 40 字符且无标点 → paragraph', () => {
    const long = 'This is a somewhat longer line without ending punctuation but too many words';
    const blocks = normalizeBlocks(long);
    expect(blocks[0].type).toBe('paragraph');
  });
});


describe('混合内容', () => {
  it('多段落 + 标题正确分类', () => {
    const text = [
      'CHAPTER ONE',
      '',
      'The story begins here with a long paragraph that continues for many words.',
      '',
      'Another paragraph follows with more content.',
    ].join('\n');

    const blocks = normalizeBlocks(text);
    expect(blocks[0]).toEqual({ type: 'heading1', text: 'CHAPTER ONE' });
    expect(blocks[1].type).toBe('paragraph');
    expect(blocks[2].type).toBe('paragraph');
  });

  it('段落内多行被正确合并', () => {
    const text = 'The tape ends with the camera pointing at\nthe ceiling, the red recording light\nstill blinking.\n\nNext paragraph.';
    const blocks = normalizeBlocks(text);
    expect(blockText(blocks[0])).toBe(
      'The tape ends with the camera pointing at the ceiling, the red recording light still blinking.',
    );
  });
});


describe('Markdown-first 解析（Marker 输出）', () => {
  it('# 开头 → heading1，文字去掉 # 前缀', () => {
    const blocks = normalizeBlocks('# Chapter One\n\nSome paragraph.');
    expect(blocks[0]).toEqual({ type: 'heading1', text: 'Chapter One' });
    expect(blocks[1].type).toBe('paragraph');
  });

  it('## 开头 → heading2', () => {
    const blocks = normalizeBlocks('## Section 2.1\n\nContent here.');
    expect(blocks[0]).toEqual({ type: 'heading2', text: 'Section 2.1' });
  });

  it('### 及更深层级 → heading2', () => {
    expect(normalizeBlocks('### Sub-section')[0].type).toBe('heading2');
    expect(normalizeBlocks('#### Deep')[0].type).toBe('heading2');
  });

  it('Markdown 标题若是对话引号开头 → paragraph（防误判）', () => {
    const blocks = normalizeBlocks('## “How special?”');
    expect(blocks[0].type).toBe('paragraph');
    expect(blockText(blocks[0])).toBe('“How special?”');
  });

  it('# 标题翻译后保留（中文）', () => {
    const blocks = normalizeBlocks('# 第一章\n\n正文内容。');
    expect(blocks[0]).toEqual({ type: 'heading1', text: '第一章' });
    expect(blocks[1].type).toBe('paragraph');
  });

  it('Markdown 与启发式共存：同一文本中混合格式', () => {
    const text = '# Markdown Title\n\nCHAPTER TWO\n\nSome body text here.';
    const blocks = normalizeBlocks(text);
    expect(blocks[0]).toEqual({ type: 'heading1', text: 'Markdown Title' });
    expect(blocks[1].type).toBe('heading1');
    expect(blocks[2].type).toBe('paragraph');
  });
});

describe('Image markers', () => {
  it('parses OB_IMAGE marker as image block', () => {
    const blocks = normalizeBlocks('[[OB_IMAGE:images/a.png|Cover]]');
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({ type: 'image', src: 'images/a.png', alt: 'Cover' });
  });

  it('keeps image markers in mixed content order', () => {
    const blocks = normalizeBlocks('Paragraph.\n\n[[OB_IMAGE:images/a.png]]\n\nAnother.');
    expect(blocks[0].type).toBe('paragraph');
    expect(blocks[1]).toEqual({ type: 'image', src: 'images/a.png', alt: 'illustration' });
    expect(blocks[2].type).toBe('paragraph');
  });
});
