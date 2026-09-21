/*
 * PalmAcademic reader adapter API v1
 *
 * The Android host provides:
 *   PalmAcademicHost.apiVersion
 *   PalmAcademicHost.publish(PagePayload)
 *
 * PagePayload = { title, sourceUrl, choices[], actions[], sections[] }
 * The host calls PalmAcademicAdapter.perform(actionId, value) for UI actions.
 * Supported section types include schedule, cards, table, fields, text and program.
 * This file owns every CUPK/EAMS DOM selector. The Android UI never queries
 * university HTML directly, so another university can replace this file and
 * its schools/*.json configuration without changing the renderer.
 */
(function () {
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  const text = value => (value || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  const lines = element => (element?.innerText || '').split(/\n+/).map(text).filter(Boolean);
  const uniqueBy = (values, key) => {
    const seen = new Set();
    return values.filter(value => { const id = key(value); if (seen.has(id)) return false; seen.add(id); return true; });
  };
  const page = (title, sections, choices = [], actions = []) =>
    ({title, sourceUrl: location.href, choices, actions, sections});
  let gpaRankData = null;
  let gpaRankLoading = false;
  let initialSemesterSelection = null;
  const scheduleProfiles = PalmAcademicHost.schoolConfig?.scheduleProfiles || [];

  function unitTime(section, location) {
    const matching = scheduleProfiles.find(profile => {
      if (!profile.locationPattern) return false;
      try { return new RegExp(profile.locationPattern, 'i').test(location || ''); }
      catch (_) { return false; }
    });
    const fallback = scheduleProfiles.find(profile => !profile.locationPattern) || scheduleProfiles[0];
    return (matching || fallback)?.unitTimes?.[String(section)] || [];
  }

  function parseScheduleEntry(rawLine) {
    const line = (rawLine || '').replace(/\u00a0/g, ' ').trim();
    const match = line.match(/^[（(]\s*(.*?)\s*[）)](?:\s*[）)])?\s*[（(]\s*(\d+)\s*[-~～—至]\s*(\d+)\s*节\s*[）)]\s*(.*)$/);
    if (!match) return null;
    const startSection = match[2];
    const endSection = match[3];
    const tail = match[4].trim();
    const teacherMatches = Array.from(tail.matchAll(/([\u3400-\u9fffA-Za-z·.'-]{1,40})\s*\(\s*\d{4,}\s*\)/g));
    const teacher = teacherMatches.map(item => item[1]).join('/');
    const location = text(teacherMatches.length ? tail.slice(0, teacherMatches[0].index) : tail);
    const weeks = match[1]
      .replace(/\s*周\s*/g, '')
      .replace(/[~～—至]/g, '-')
      .replace(/[,，;；、]+/g, '、')
      .replace(/[（）()]/g, '')
      .replace(/\s+/g, '');
    return {
      raw: text(line),
      weeks,
      startSection,
      endSection,
      teacher,
      location,
      startTime:unitTime(startSection, location)?.[0] || '',
      endTime:unitTime(endSection, location)?.[1] || ''
    };
  }

  function semesterOrder(option) {
    const label = text(option.label ?? option.text ?? '');
    const years = label.match(/(\d{4})\s*[-—]\s*(\d{4})/);
    const season = /春/.test(label) ? 2 : /秋/.test(label) ? 1 : 0;
    if (years) return Number(years[1]) * 10 + season;
    return Number(option.value) || 0;
  }

  function semesterOptions(element) {
    const selectize = element?.selectize;
    const values = selectize?.options
      ? Object.values(selectize.options).map(option => ({value:String(option.value ?? ''), label:text(option.text)}))
      : Array.from(element?.options || []).map(option => ({value:option.value, label:text(option.text)}));
    return uniqueBy(values.filter(option => option.label), option => option.value)
      .sort((a, b) => semesterOrder(b) - semesterOrder(a));
  }

  function selectChoice(selector, id, label, fallbackOptions = []) {
    const element = document.querySelector(selector);
    if (!element) return null;
    const selectize = element.selectize;
    let options = id === 'semester' ? semesterOptions(element) : (selectize?.options
      ? Object.values(selectize.options).map(option => ({value:String(option.value ?? ''), label:text(option.text)}))
      : Array.from(element.options || []).map(option => ({value:option.value, label:text(option.text)})));
    fallbackOptions.forEach(option => {
      if (!options.some(item => item.value === option.value)) options.unshift(option);
    });
    options = uniqueBy(options.filter(option => option.label), option => option.value);
    const value = String(selectize?.getValue?.() ?? element.value ?? '');
    return {id, label, value, options};
  }

  function schedulePage() {
    const table = document.querySelector('table.courseTable');
    if (!table) return null;
    const names = Array.from(table.querySelectorAll('thead th')).map(node => text(node.innerText)).filter(Boolean);
    const weekdays = names.length >= 7 ? names.slice(-7) : ['星期一','星期二','星期三','星期四','星期五','星期六','星期日'];
    const days = weekdays.map((name, index) => ({name, lessons: readDay(index + 1)}));
    const semester = text(document.querySelector('#allSemesters option:checked')?.innerText || document.querySelector('#allSemesters + .selectize-control .item')?.innerText);
    const semesterChoice = selectChoice('#allSemesters', 'semester', '选择学期');
    return page(
      '我的课表',
      [{
        type:'schedule',
        title:semester || '本学期课表',
        semesterStartDate:text(document.querySelector('#startDate')?.innerText),
        days
      }],
      semesterChoice ? [semesterChoice] : []
    );

    function readDay(dayIndex) {
      const cells = Array.from(table.querySelectorAll('td.td-content')).filter(cell =>
        Array.from(cell.classList).some(name => Number(name) === dayIndex)
      );
      const lessons = [];
      cells.forEach(cell => {
        const blocks = Array.from(cell.querySelectorAll(':scope > .tdHtml')).filter(block => {
          const opacity = getComputedStyle(block).opacity;
          return opacity !== '0' && block.style.opacity !== '0';
        });
        blocks.forEach(block => {
          const children = Array.from(block.children);
          children.forEach((child, index) => {
            if (!child.classList.contains('course-name')) return;
            const title = text(child.innerText);
            const code = text(children[index + 1]?.innerText);
            const metaLines = (children[index + 2]?.innerText || '')
              .split(/\n+/).map(value => value.replace(/\u00a0/g, ' ').trim()).filter(Boolean);
            const group = text(children[index + 3]?.innerText);
            const entries = metaLines.map(parseScheduleEntry).filter(Boolean);
            if (!entries.length) {
              lessons.push({title, subtitle:code, fields:[
                {label:'时间与地点', value:metaLines.map(text).join(' · ')},
                {label:'教学班', value:group}
              ]});
              return;
            }
            entries.forEach(entry => lessons.push({
              title,
              subtitle:code,
              schedule:entry,
              fields:[
                {label:'周数', value:entry.weeks},
                {label:'节次', value:`${entry.startSection}-${entry.endSection}节`},
                {label:'老师', value:entry.teacher},
                {label:'地点', value:entry.location},
                {label:'教学班', value:group}
              ]
            }));
          });
        });
      });
      return uniqueBy(lessons, item => item.title + item.subtitle + (item.schedule
        ? [item.schedule.weeks,item.schedule.startSection,item.schedule.endSection,item.schedule.teacher,item.schedule.location].join('|')
        : item.fields[0]?.value || ''))
        .sort((a,b) => Number(a.schedule?.startSection || 99) - Number(b.schedule?.startSection || 99));
    }
  }

  function gradePage() {
    const tables = Array.from(document.querySelectorAll('table.student-grade-table'));
    const sections = tables.map((table, tableIndex) => {
      const rows = Array.from(table.querySelectorAll('tr'));
      const semester = nearestHeading(table) || '第 ' + (tableIndex + 1) + ' 学期';
      const cards = rows.slice(1).map(row => {
        const cells = Array.from(row.children).map(cell => text(cell.innerText));
        if (cells.length < 4 || !cells[0]) return null;
        const nameLines = lines(row.children[0]);
        return {
          title:nameLines[0] || cells[0],
          subtitle:nameLines.slice(1).join(' · '),
          accent:cells[3],
          fields:[
            {label:'学分',value:cells[1]},
            {label:'绩点',value:cells[2]},
            {label:'成绩明细',value:cells[5] || cells[4]}
          ].filter(field => field.value)
        };
      }).filter(Boolean);
      return cards.length ? {type:'cards', title:semester, cards} : null;
    }).filter(Boolean);
    if (!sections.length) return null;
    if (gpaRankData !== null) {
      const rankValue = (rank, count, rate) => {
        const base = `${rank ?? '--'}/${count ?? '--'}`;
        return rate == null ? base : `${base} · 前${Number(rate).toFixed(2)}%`;
      };
      sections.unshift({type:'stats', title:'GPA与排名', items:[
        {label:'GPA', value:String(gpaRankData.gpa ?? '--')},
        {label:'班级排名', value:rankValue(gpaRankData.adminclassRank, gpaRankData.adminclassStdCount, gpaRankData.adminclassRankRate)},
        {label:'专业排名', value:rankValue(gpaRankData.rank, gpaRankData.majorStdCount, gpaRankData.rankRate)}
      ]});
    }
    const semesterChoice = selectChoice('#semester', 'semester', '选择学期', [{value:'', label:'全部学期'}]);
    return page(
      '课程成绩',
      sections.length ? sections : [{type:'text',title:'提示',paragraphs:['暂无成绩数据']}],
      semesterChoice ? [semesterChoice] : []
    );
  }

  function examPage() {
    const table = document.querySelector('table.exam-table');
    if (!table) return page('考试信息', [{type:'text',title:'提示',paragraphs:['暂无考试数据']}]);
    const rows = Array.from(table.querySelectorAll('tr'));
    const headers = Array.from(rows[0]?.children || []).map(cell => text(cell.innerText));
    const messages = [];
    const cards = [];
    rows.slice(1).forEach(row => {
      const cells = Array.from(row.children).map(cell => text(cell.innerText));
      if (row.children.length === 1) { if (cells[0]) messages.push(cells[0]); return; }
      if (cells.length < 5) return;
      cards.push({
        title:cells[2] || cells[0],
        subtitle:cells[1],
        accent:cells[6],
        fields:headers.map((header,index) => ({label:header,value:cells[index]})).filter(field =>
          field.value && !['课程名称','课程代码','考试状态'].includes(field.label)
        )
      });
    });
    const sections = [];
    if (cards.length) sections.push({type:'cards',title:'考试安排',cards});
    if (messages.length) sections.push({type:'text',title:'提示',paragraphs:messages});
    return page('考试信息', sections);
  }

  function progressPage() {
    const counts = Array.from(document.querySelectorAll('.person-credit-count span')).map(node => text(node.innerText));
    const root = document.querySelector('#course-modules') || document;
    const modules = Array.from(root.querySelectorAll('.module-tpl.depth-1')).map(readProgramModule);
    return page('培养方案完成情况', [{
      type:'program',
      title:'培养方案栏目',
      completedCredits:counts[0] || '',
      requiredCredits:counts[2] || '',
      modules
    }]);

    function readProgramModule(element) {
      const titleElement = element.querySelector(':scope > .m-title');
      const content = element.querySelector(':scope > .m-content');
      const table = content?.querySelector(':scope > table.c-table');
      const tableRows = table ? Array.from(table.querySelectorAll('tr')).map(row =>
        Array.from(row.children).map(cell => text(cell.innerText))
      ).filter(row => row.some(Boolean)) : [];
      const childContainer = content?.querySelector(':scope > .c-children');
      const children = childContainer
        ? Array.from(childContainer.children).filter(child => child.classList.contains('module-tpl')).map(readProgramModule)
        : [];
      return {
        id:element.id || text(titleElement?.querySelector('.module-name')?.innerText),
        title:text(titleElement?.querySelector('.module-name')?.innerText),
        depth:Number(element.dataset.depth || 1),
        status:element.dataset.result || '',
        requirements:Array.from(titleElement?.querySelectorAll(':scope > .title-item') || [])
          .map(node => text(node.innerText)).filter(Boolean),
        headers:tableRows[0] || [],
        courses:tableRows.slice(1),
        children
      };
    }
  }

  function nearestHeading(element) {
    const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4')).filter(node => text(node.innerText) && text(node.innerText) !== '初始化数据....');
    return text(headings.filter(node => node.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING).pop()?.innerText);
  }

  function read() {
    const path = location.pathname;
    if (path.includes('/course-table')) return schedulePage();
    if (path.includes('/grade/sheet')) return gradePage();
    if (path.includes('/exam-arrange')) return examPage();
    if (path.includes('/program-completion-preview')) return progressPage();
    return page(document.title || '教务信息', [{type:'text',title:'内容',paragraphs:[text(document.body.innerText)]}]);
  }

  function setSelectValue(selector, value) {
    const element = document.querySelector(selector);
    if (!element) return false;
    if (element.selectize) {
      element.selectize.setValue(value);
    } else {
      element.value = value;
      element.dispatchEvent(new Event('change', {bubbles:true}));
    }
    return true;
  }

  function selectLatestSemesterIfNeeded() {
    if (initialSemesterSelection !== null) return false;
    const path = location.pathname;
    const selector = path.includes('/course-table') ? '#allSemesters' : path.includes('/grade/sheet') ? '#semester' : '';
    if (!selector) return false;
    const element = document.querySelector(selector);
    if (!element) return false;
    const current = String(element.selectize?.getValue?.() ?? element.value ?? '');
    if (current) {
      initialSemesterSelection = current;
      return false;
    }
    const latest = semesterOptions(element).find(option => option.value);
    if (!latest) return false;
    initialSemesterSelection = latest.value;
    return setSelectValue(selector, latest.value);
  }

  function loadGpaRank() {
    if (gpaRankLoading || gpaRankData || !location.pathname.includes('/grade/sheet')) return;
    const source = Array.from(document.scripts).map(script => script.textContent || '').join('\n');
    const studentId = source.match(/var\s+studentId\s*=\s*(\d+)/)?.[1];
    if (!studentId) return;
    gpaRankLoading = true;
    const gradeBasePath = location.pathname.split('/semester-index/')[0].replace(/\/$/, '');
    fetch(`${gradeBasePath}/get-gpa-rank-by-std/${studentId}`, {credentials:'same-origin'})
      .then(response => response.ok ? response.json() : Promise.reject(new Error(String(response.status))))
      .then(data => { gpaRankData = data || {}; })
      .catch(() => { gpaRankData = {}; })
      .finally(() => { gpaRankLoading = false; publish(); });
  }

  function perform(actionId, value) {
    const path = location.pathname;
    if (actionId === 'semester') {
      const changed = setSelectValue(path.includes('/course-table') ? '#allSemesters' : '#semester', value);
      if (changed) {
        setTimeout(publish, 120);
        setTimeout(publish, 600);
        setTimeout(publish, 1400);
      }
      return changed;
    }
    return false;
  }

  let timer;
  let lastPayloadJson = '';
  function publishNow() {
    if (selectLatestSemesterIfNeeded()) return;
    loadGpaRank();
    const payload = read();
    if (!payload) return;
    const payloadJson = JSON.stringify(payload);
    if (payloadJson === lastPayloadJson) return;
    lastPayloadJson = payloadJson;
    PalmAcademicHost.publish(payload);
  }

  function publish() {
    clearTimeout(timer);
    timer = setTimeout(publishNow, 70);
  }

  window.PalmAcademicAdapter = {apiVersion:1, read, publish, perform};
  const observer = new MutationObserver(publish);
  observer.observe(document.body, {childList:true, subtree:true, characterData:true});
  publishNow();
  setTimeout(publish, 350);
  setTimeout(publish, 1000);
  loadGpaRank();
})();
