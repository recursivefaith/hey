#!/usr/bin/env node

import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal'; 

marked.use(markedTerminal({
  tabs: 2
}));

async function main() {
  let markdownInput = "";

  for await (const chunk of process.stdin) {
    markdownInput += chunk;
  }

  if (markdownInput) {
    const terminalOutput = marked.parse(markdownInput);
    process.stdout.write(terminalOutput);
  }
}

main().catch(error => {
  console.error("Error processing markdown:", error);
  process.exit(1);
});
