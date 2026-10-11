#!/usr/bin/env python3
"""Reference-only smoke test. Requires playwright and a local Chromium.
Renders the inline preview without navigation or any network access.
No production App services or repository are inspected by this test.
"""
from pathlib import Path
import json,re,os
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1];HTML=(ROOT/'preview.html').read_text()
results=[];screens=[];errors=[]
def record(name,passed,detail=''):
 results.append({'test':name,'passed':bool(passed),'detail':detail});assert passed,(name,detail)
with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path=os.getenv('CHROMIUM_PATH','/usr/bin/chromium'),headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
 ctx=browser.new_context(viewport={'width':390,'height':844},device_scale_factor=2)
 page=ctx.new_page();page.on('pageerror',lambda e:errors.append(str(e)))
 def load(screen=''):
  global page
  page.close();page=ctx.new_page();page.set_default_timeout(5000);page.on('pageerror',lambda e:errors.append(str(e)))
  text=HTML.replace('new URLSearchParams(location.search)',f'new URLSearchParams({json.dumps(screen)})')
  page.set_content(text,wait_until='load');page.evaluate('document.fonts.ready');page.evaluate('document.getAnimations().forEach(a=>a.finish())')
 def shot(name):
  page.wait_for_function("!document.querySelector('#toast').classList.contains('show')",timeout=4500)
  page.screenshot(path=str(ROOT/'references'/name),animations='disabled');screens.append({'file':'references/'+name,'viewportCSS':[390,844],'pixelSize':[780,1688],'dpr':2,'animations':'finished for capture'})
 load();record('Library is the default screen',page.locator('#libraryScreen').is_visible());shot('01-library.png')
 record('No separate task navigation',page.locator('#taskScreen,.bottom-nav').count()==0)
 record('No manual glossary gate',not any(x in page.inner_text('body') for x in ['待确认术语','核对术语','确认译名并开始']))
 record('Assets are loaded',page.locator('img').evaluate_all('(es)=>es.every(e=>e.complete&&e.naturalWidth>0)'))
 row=page.locator('[data-row="mountain"]');before=row.locator('.percent').inner_text();row.locator('[data-action="pause"]').click()
 record('Pause retains progress',before==row.locator('.percent').inner_text() and '已暂停' in row.inner_text())
 row.locator('[data-action="pause"]').click();record('Resume retains progress',before==row.locator('.percent').inner_text())
 page.locator('[data-filter="processing"]').click();record('Processing filter',page.locator('.shelf-book').count()==2)
 page.locator('[data-filter="complete"]').click();record('Complete filter',page.locator('.shelf-book').count()==1)
 page.locator('[data-filter="all"]').click()
 row.locator('[data-action="progress"]').click();record('Premium parallel roles',page.locator('.detail-role.active').count()==2);shot('03-progress.png')
 page.locator('#sheetBody [data-action="read"]').click();record('Read from progress',page.locator('#readerScreen').is_visible())
 page.locator('#backBtn').click();record('Back restores book progress sheet',page.locator('#overlay.open .detail-roles').is_visible());page.locator('#sheetClose').click()
 row.locator('[data-action="book-menu"]').click();page.locator('#sheetBody [data-action="names"]').click();record('Optional names from book menu',page.locator('#namesScreen').is_visible());shot('06-names.png')
 page.get_by_role('button',name='修改 Eleanor Vale 的译名').click();shot('07-edit-name.png')
 page.locator('#nameValue').fill('');page.get_by_role('button',name='保存',exact=True).click();record('Empty name prevented',page.locator('#nameError').is_visible())
 page.locator('#nameValue').fill('艾琳娜·维尔');page.get_by_role('button',name='保存',exact=True).click();record('Name edit saved',page.locator('.name-target').first.inner_text()=='艾琳娜·维尔')
 record('Saving a name does not start a task',page.locator('#namesScreen').is_visible() and not page.locator('#overlay').is_visible())
 page.get_by_role('button',name='修改 Eleanor Vale 的译名').click();page.locator('#nameValue').fill('取消用的草稿');page.get_by_role('button',name='取消',exact=True).click();record('Cancel preserves stored name',page.locator('.name-target').first.inner_text()=='艾琳娜·维尔')
 load('?screen=quality&tier=3');shot('02-quality-premium.png')
 for i in range(4):
  page.locator(f'[data-tier="{i}"]').click();record('Quality tier role count '+str(i),page.locator('.actor:not(.absent)').count()==i+1)
  if i<3:shot(f'02-quality-tier-{i}.png')
 record('No terminology modes in setup',page.locator('#termsSelect').count()==0)
 record('All eight style presets retained',page.locator('#styleSelect option').count()==9)
 page.locator('#targetLanguage').select_option('日语');record('Target language selectable',page.locator('#targetLanguage').input_value()=='日语')
 page.locator('#targetLanguage').select_option('中文')
 page.locator('.setup-details summary').click();page.locator('#qualityTail').scroll_into_view_if_needed();shot('02-quality-options.png')
 load('?screen=reader');shot('04-reader.png');page.locator('[data-mode="bilingual"]').click();record('Bilingual content shown',page.locator('#readingCopy p.orig').count()>0);shot('05-bilingual.png')
 page.locator('#readerSettings').click();before=page.locator('#readingCopy').evaluate('(e)=>getComputedStyle(e).fontSize');page.locator('[data-action="font-up"]').click();after=page.locator('#readingCopy').evaluate('(e)=>getComputedStyle(e).fontSize');record('Reading font size updates',before!=after);page.locator('#motionToggle').check();record('Reduced motion flag',page.locator('#device').evaluate('(e)=>e.classList.contains("motion-off")'))
 load('?screen=import');shot('08-import.png');record('Document only file picker',all(x not in page.locator('#filePicker').get_attribute('accept') for x in ['image','.jpg','.png','.heic']))
 page.locator('#primaryAction').click();page.locator('#primaryAction').click();record('New task starts without manual confirmation',page.locator('#libraryScreen').is_visible() and page.locator('.shelf-book').first.get_attribute('class').find('status-running')>=0)
 load('?screen=names&book=field');shot('10-empty-names.png');record('Names are optional for new books','不用提前整理' in page.locator('#namesScreen').inner_text())
 load('?screen=account');shot('09-account-style-only.png')
 for w,h in [(320,568),(375,812),(430,932),(768,1024)]:
  load();page.set_viewport_size({'width':w,'height':h});record(f'No horizontal document overflow at {w}',page.evaluate('document.documentElement.scrollWidth<=innerWidth'))
  page.locator('[data-row="mountain"] [data-action="progress"]').click();record(f'Progress sheet reachable at {w}',page.locator('#sheetClose').is_visible())
 record('No JavaScript runtime errors',not errors,errors)
 browser.close()
report={'scope':'HTML reference only; no production application tested','rendering':'local Chromium, inline content; no network navigation','checks':results,'passed':all(r['passed'] for r in results),'screenshots':screens,'not_tested':['iOS native rendering and gestures','VoiceOver / native Dynamic Type','production API and payment integration','production data migration','reload persistence from file:// in this environment']}
(ROOT/'qa/reference-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({'passed':report['passed'],'checks':len(results),'screenshots':len(screens),'errors':errors},ensure_ascii=False))
