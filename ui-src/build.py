# Assemble ../game.html from the template and the case images.
#   python3 -I ui-src/build.py      (run from the Game folder)
import base64, os
here = os.path.dirname(os.path.abspath(__file__))
def uri(name, mime):
    with open(os.path.join(here, name), 'rb') as f:
        return f'data:{mime};base64,' + base64.b64encode(f.read()).decode()
with open(os.path.join(here, 'game.template.html'), encoding='utf-8') as f:
    t = f.read()
t = (t.replace('__CASE_IMG__', uri('case-color.jpg', 'image/jpeg'))
      .replace('__BODY_MASK__', uri('body-mask.png', 'image/png'))
      .replace('__MASK__', uri('case-mask.png', 'image/png')))
out = os.path.join(here, '..', 'game.html')
with open(out, 'w', encoding='utf-8') as f:
    f.write(t)
print('wrote', os.path.normpath(out), os.path.getsize(out) // 1024, 'KB')
