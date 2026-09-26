import type {PrismTheme} from 'prism-react-renderer';

const lorenTheme: PrismTheme = {
  plain: {
    color: '#ebe6e8',
    backgroundColor: '#151515',
  },
  styles: [
    {
      types: ['comment', 'prolog', 'doctype', 'cdata'],
      style: {color: '#958d91', fontStyle: 'italic'},
    },
    {
      types: ['keyword', 'important', 'atrule', 'selector'],
      style: {color: '#f293b8'},
    },
    {
      types: ['string', 'char', 'attr-value', 'regex', 'url', 'inserted', 'template-string'],
      style: {color: '#7ab0d8'},
    },
    {
      types: ['number', 'boolean', 'constant', 'symbol'],
      style: {color: '#ffa0c7'},
    },
    {
      types: ['function', 'function-variable'],
      style: {color: '#dcecf8'},
    },
    {
      types: ['builtin', 'class-name', 'tag', 'namespace'],
      style: {color: '#77a8ce'},
    },
    {
      types: ['operator', 'punctuation'],
      style: {color: '#a29a9e'},
    },
    {
      types: ['variable', 'property', 'attr-name', 'parameter'],
      style: {color: '#ebe6e8'},
    },
    {
      types: ['deleted'],
      style: {color: '#f293b8'},
    },
    {
      types: ['bold'],
      style: {fontWeight: 'bold'},
    },
    {
      types: ['italic'],
      style: {fontStyle: 'italic'},
    },
  ],
};

export default lorenTheme;
