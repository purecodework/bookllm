import { render, screen } from '@testing-library/react';
import { TextBlocks } from '@/components/reader/text-blocks';

describe('TextBlocks image rendering', () => {
  it('renders OB_IMAGE marker as img element', () => {
    render(
      <TextBlocks
        text={'[[OB_IMAGE:images/a.png|Cover]]'}
        fontSize="text-base"
        lineHeight="leading-7"
        bookId="book-1"
      />,
    );

    const image = screen.getByRole('img', { name: 'Cover' });
    expect(image).toBeInTheDocument();
    expect(image.getAttribute('src')).toContain('/books/book-1/image-asset?path=');
  });
});
