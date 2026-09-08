"""Optional, bounded motion suggestions carried by the ordinary chat reply."""
import re

REACTIONS = frozenset({'none', 'affection', 'celebration', 'amusement', 'greeting',
                       'agreement', 'gratitude', 'curiosity', 'empathy'})
PROMPT = (
    '\n\nThe user has enabled expressive reactions for the on-screen 3D companion. '
    'After your normal reply, you may append one private motion suggestion on its own line: '
    '<<openclam:motion CATEGORY>>. CATEGORY must be one of none, affection, celebration, '
    'amusement, greeting, agreement, gratitude, curiosity, empathy. Choose from the whole '
    'conversation and the tone of this reply. Most factual, technical or routine replies '
    'should use none. Affection is for personal warmth directed to the user, not for '
    'mentions of hearts or loving a product. Celebration is for genuinely happy news, '
    'or a request to be cheerful and playful, not the routine phrase happy to help. Never celebrate grief, danger, distress, bad news '
    'or sarcasm. Do not invent feelings or change your answer to justify a gesture. '
    'This is a nonbinding visual suggestion; manual controls override it. Never explain '
    'or speak the directive. Omit it when using a media creation directive.'
)
DIRECTIVE = re.compile(r'<<openclam:motion\s+([^<>\r\n]{1,80})>>', re.I)


def extract(text, *, partial=False):
    value = str(text or '')
    matches = list(DIRECTIVE.finditer(value))
    suggestion = matches[-1].group(1).strip().lower() if matches else None
    if suggestion not in REACTIONS:
        suggestion = None
    value = DIRECTIVE.sub('', value)
    marker = value.lower().rfind('<<')
    if marker >= 0:
        tail = value[marker:].lower()
        if tail.startswith('<<openclam:motion') or (partial and '<<openclam:motion'.startswith(tail)):
            value = value[:marker]
    if partial and value.endswith('<'):
        value=value[:-1]
    return value.rstrip(), suggestion
