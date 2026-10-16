// Entry point for OpenCode's local-directory plugin form ("plugins": ["/path/to/fablepowers"]),
// which loads <dir>/index and ignores package.json main. Git/npm installs use main.
export { default } from './opencode/index.js';
