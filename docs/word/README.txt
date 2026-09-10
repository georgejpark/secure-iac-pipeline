Word (.docx) exports of the demo documents.

GENERATED FILES. The Markdown in docs/final/ is the source of truth.
If you edit a document, edit the .md and re-export; do not edit the .docx.

Re-export:
  python3 -m venv /tmp/_docx && /tmp/_docx/bin/pip install pypandoc_binary
  /tmp/_docx/bin/python - <<'PY'
  import pypandoc, glob, os
  for f in sorted(glob.glob('docs/final/*.md')) + ['README.md']:
      body = open(f).read().replace('<!-- title -->\n', '')
      open('/tmp/_conv.md','w').write(body)
      pypandoc.convert_file('/tmp/_conv.md', 'docx',
          outputfile='docs/word/' + os.path.basename(f).replace('.md','.docx'),
          extra_args=['--toc','--toc-depth=2','--standalone',
                      '--syntax-highlighting=tango','-f','gfm+pipe_tables',
                      '--resource-path=docs/final:docs:docs/img:.'])
  PY

NOT INCLUDED: the three draw.io diagrams in docs/diagrams/ are vector source and
do not embed in Word. Open them at app.diagrams.net and use File > Export as >
PNG if you need them inside a document. Doc 7 does embed the existing
system-architecture.png.
