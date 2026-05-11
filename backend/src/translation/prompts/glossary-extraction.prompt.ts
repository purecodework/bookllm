export const GLOSSARY_EXTRACTION_PROMPT = {
  bookContext: {
    intro: (targetLang: string) =>
      `You are building a structured book context package for a document to be translated into ${targetLang}.`,
    analysisScope:
      'Analyze only the section text below. It is one sequential section from a longer book.',
    extractScope:
      'Extract character names, place names, organization names, key domain-specific terms, protected source terms, forbidden translations, and a section summary when section metadata is provided.',
    fields: (targetLang: string) => [
      'Return one JSON object with:',
      '  - version: 2',
      '  - entries: array of {source,target,type,aliases,description}',
      `  - each target must be the correct ${targetLang} translation`,
      '  - type must be "character" | "place" | "org" | "term"',
      '  - aliases must include likely short forms used later, or []',
      '  - description must be one short sentence of context',
      '  - doNotTranslate: source terms that should normally remain unchanged',
      '  - forbiddenTranslations: array of {source,forbidden,prefer?}',
      '  - styleGuide: {}',
      '  - chapterSummaries: []',
      '  - sections: array of {id,chapterId?,title?,pageStart?,pageEnd?,summary} for the current section',
    ],
    rules: [
      'Rules:',
      '  - Prefer omission over false positives: when in doubt, skip the entry',
      '  - Do NOT extract common nouns, verbs, adjectives, or pronouns',
      '  - Do NOT extract entries already in the existing glossary (listed below)',
      '  - Use only this section context; do not invent full-book facts',
      '  - If text explicitly says a source term must not use a translation, put that translation in forbiddenTranslations',
      '  - Put short forms under aliases instead of creating duplicate entries',
      '  - Keep styleGuide as an empty object; style is handled later by the polish pipeline',
      '  - Keep chapterSummaries as an empty array; use sections for source-context summaries',
      '  - Always include one sections item for the current [SECTION] marker when present',
      '  - Keep each section summary under 50 words',
      '  - Return ONLY a valid JSON object, nothing else',
    ],
    existingGlossary: (keys: string[]) =>
      keys.length > 0
        ? `Existing glossary - skip these: ${keys.slice(0, 200).join(', ')}`
        : 'Existing glossary: (empty)',
    returnFormat:
      'Return format: {"version":2,"entries":[{"source":"...","target":"...","type":"character","aliases":["..."],"description":"..."}],"doNotTranslate":[],"forbiddenTranslations":[],"styleGuide":{},"chapterSummaries":[],"sections":[]}',
    fullTextHeader: 'Section text:',
    systemPrompt: 'You extract structured translation context. Return only a valid JSON object.',
  },
  page: {
    intro: (targetLang: string) =>
      `Extract proper nouns and key domain-specific terms from the source text and translate each into ${targetLang}.`,
    rules: [
      'Classify each as one of: "character" | "place" | "org" | "term"',
      'Return ONLY a JSON object. Example: {"version":2,"entries":[{"source":"Alice","target":"<translation>","type":"character","aliases":[],"description":"person"}],"doNotTranslate":[],"forbiddenTranslations":[],"styleGuide":{},"chapterSummaries":[],"sections":[]}',
      'If no proper nouns are found, return the same object with empty arrays.',
      'Rules:',
      '- Prefer omission over false positives: if unsure whether a word is a proper noun or important recurring term, skip it.',
      '- Do NOT extract common nouns, verbs, adjectives, or pronouns.',
      '- For multi-part personal names, put likely short forms under aliases.',
    ],
    alreadyKnown: (keys: string[]) =>
      keys.length > 0 ? `- Already known - skip these: ${keys.join(', ')}` : '',
    sourceHeader: 'Source text:',
  },
  continuation: {
    intro: (targetLang: string) =>
      `The previous response was truncated. Continue extracting proper nouns from the source text into ${targetLang}.`,
    rules: [
      'Output ONLY new entries not already listed below.',
      'Return ONLY a JSON object with version:2 and entries/doNotTranslate/forbiddenTranslations/styleGuide/chapterSummaries/sections keys.',
      'If there are no more entries, return the same object with empty arrays.',
    ],
    alreadyExtracted: (terms: string[]) =>
      terms.length > 0 ? `Already extracted - skip: ${terms.join(', ')}` : '',
    sourceHeader: 'Source text:',
  },
  reduction: {
    intro: (targetLang: string) =>
      `Merge these extracted book context packages into one canonical package for translation into ${targetLang}.`,
    rules: [
      'Return ONLY one valid JSON object.',
      'Preserve version:2 and the entries/doNotTranslate/forbiddenTranslations/styleGuide/chapterSummaries/sections keys.',
      'Deduplicate entries by canonical source name; merge aliases and keep the clearest target.',
      'Prefer an existing or earlier target when several targets conflict unless a later one is clearly more specific.',
      'Do not invent entries not present in the packages.',
      'Keep styleGuide concise: at most one sentence per field.',
      'Keep summaries concise and preserve section ids/page ranges.',
    ],
    packagesHeader: 'Packages to merge:',
  },
} as const;
