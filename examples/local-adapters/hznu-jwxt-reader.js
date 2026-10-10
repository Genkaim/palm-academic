(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  const clean = value => String(value || '')
    .replace(/\u00a0/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const lineList = element => String(element?.innerText || '')
    .split(/\n+/)
    .map(clean)
    .filter(Boolean);
  const page = (title, sections, choices = []) => ({
    title,
    sourceUrl: location.href,
    choices,
    actions: [{id: 'refresh', label: '刷新网页', value: ''}],
    sections
  });
  const scheduleProfiles = window.PalmAcademicHost.schoolConfig?.scheduleProfiles || [];

  function unitTime(section, location) {
    const matched = scheduleProfiles.find(profile => {
      if (!profile.locationPattern) return false;
      try { return new RegExp(profile.locationPattern, 'i').test(location || ''); }
      catch (_) { return false; }
    });
    const fallback = scheduleProfiles.find(profile => !profile.locationPattern) || scheduleProfiles[0];
    return (matched || fallback)?.unitTimes?.[String(section)] || [];
  }

  function selectChoice(selector, id, label, includeEmpty = false) {
    const element = document.querySelector(selector);
    if (!element) return null;
    const options = Array.from(element.options || [])
      .map(option => ({value: String(option.value || ''), label: clean(option.textContent)}))
      .filter(option => option.label && (includeEmpty || option.value));
    return {id, label, value: String(element.value || ''), options};
  }

  function selectedLabel(selector) {
    const element = document.querySelector(selector);
    return clean(element?.options?.[element.selectedIndex]?.textContent);
  }

  function gridRows(tableId = 'tabGrid') {
    return Array.from(document.querySelectorAll(`#${tableId} tr`))
      .filter(row => row.classList.contains('jqgrow') || row.classList.contains('ui-widget-content'))
      .map(row => {
        const result = {};
        Array.from(row.cells).forEach(cell => {
          const fullName = cell.getAttribute('aria-describedby') || '';
          const prefix = `${tableId}_`;
          if (fullName.startsWith(prefix)) result[fullName.slice(prefix.length)] = clean(cell.innerText);
        });
        return result;
      })
      .filter(row => Object.keys(row).length > 0);
  }

  function extract(raw, pattern) {
    return clean(raw.match(pattern)?.[1]);
  }

  function schedulePage() {
    const table = document.querySelector('#kblist_table');
    const choices = [
      selectChoice('#xnm', 'schedule-year', '学年'),
      selectChoice('#xqm', 'schedule-term', '学期')
    ].filter(Boolean);
    if (!table) return page('个人课表', [{type: 'text', title: '正在加载', paragraphs: ['等待课表数据加载。']}], choices);

    const dayNames = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    const lessonsByDay = new Map(dayNames.map(name => [name, []]));
    let currentDay = '';
    let currentSection = '';

    Array.from(table.rows).slice(2).forEach(row => {
      const cells = Array.from(row.cells);
      if (!cells.length) return;
      const firstText = clean(cells[0].innerText);
      if (/^星期[一二三四五六日]$/.test(firstText)) {
        currentDay = firstText;
        currentSection = '';
        return;
      }

      let infoCell = null;
      const sectionMatch = firstText.match(/^(\d+)\s*[-~～—至]\s*(\d+)$/);
      if (sectionMatch) {
        currentSection = `${sectionMatch[1]}-${sectionMatch[2]}`;
        infoCell = cells[1] || null;
      } else if (currentSection && cells.length === 1) {
        infoCell = cells[0];
      }
      if (!currentDay || !currentSection || !infoCell) return;

      const raw = clean(infoCell.innerText);
      if (!raw || /^其它课程[：:]/.test(raw)) return;
      const sections = currentSection.split('-');
      const startSection = sections[0];
      const endSection = sections[1] || startSection;
      const titleLine = lineList(infoCell)[0] || raw.split(/周数[：:]/)[0];
      const title = clean(titleLine.replace(/[★○●@]+$/g, ''));
      const weeks = extract(raw, /周数\s*[：:]\s*(.*?)(?=\s+校区\s*[：:]|$)/)
        .replace(/^第/, '')
        .replace(/周/g, '');
      const campus = extract(raw, /校区\s*[：:]\s*(.*?)(?=\s+上课地点\s*[：:]|$)/);
      const room = extract(raw, /上课地点\s*[：:]\s*(.*?)(?=\s+教师\s*[：:]|$)/);
      const teacher = extract(raw, /教师\s*[：:]\s*(.*?)(?=\s+教学班组成\s*[：:]|$)/);
      const className = extract(raw, /教学班组成\s*[：:]\s*(.*)$/);
      const locationText = clean([campus, room].filter(Boolean).join(' '));
      const start = unitTime(startSection, locationText);
      const end = unitTime(endSection, locationText);
      lessonsByDay.get(currentDay).push({
        title,
        subtitle: className,
        schedule: {
          raw,
          weeks,
          startSection,
          endSection,
          teacher,
          location: locationText,
          startTime: start[0] || '',
          endTime: end[1] || ''
        },
        fields: [
          {label: '周数', value: weeks},
          {label: '节次', value: `${startSection}-${endSection}节`},
          {label: '教师', value: teacher},
          {label: '地点', value: locationText},
          {label: '教学班', value: className}
        ].filter(field => field.value)
      });
    });

    const title = `${selectedLabel('#xnm')}学年第${selectedLabel('#xqm')}学期`;
    return page('个人课表', [{
      type: 'schedule',
      title: title.replace('学年学年', '学年') || '当前学期课表',
      semesterStartDate: '',
      days: dayNames.map(name => ({
        name,
        lessons: lessonsByDay.get(name).sort((a, b) =>
          Number(a.schedule.startSection) - Number(b.schedule.startSection)
        )
      }))
    }], choices);
  }

  function gradePage() {
    const choices = [
      selectChoice('#xnm', 'grade-year', '学年', true),
      selectChoice('#xqm', 'grade-term', '学期', true)
    ].filter(Boolean);
    const cards = gridRows().map(row => ({
      title: row.kcmc || '未命名课程',
      subtitle: clean([row.xnmmc && `${row.xnmmc}学年`, row.xqmmc && `第${row.xqmmc}学期`, row.kcxzmc].filter(Boolean).join(' · ')),
      accent: row.cj || '',
      fields: [
        {label: '成绩', value: row.cj},
        {label: '学分', value: row.xf},
        {label: '绩点', value: row.jd},
        {label: '学分绩点', value: row.xfjd},
        {label: '课程性质', value: row.kcxzmc},
        {label: '任课教师', value: row.jsxm},
        {label: '考核方式', value: row.khfsmc},
        {label: '课程代码', value: row.kch},
        {label: '开课学院', value: row.kkbmmc},
        {label: '课程标记', value: row.kcbj}
      ].filter(field => field.value)
    }));
    const sections = cards.length
      ? [{type: 'cards', title: `共 ${cards.length} 门课程`, cards}]
      : [{type: 'text', title: '暂无成绩', paragraphs: ['当前筛选条件没有成绩，可切换学年或学期后查询。']}];
    return page('学生成绩', sections, choices);
  }

  function examPage() {
    const choices = [
      selectChoice('#cx_xnm', 'exam-year', '学年'),
      selectChoice('#cx_xqm', 'exam-term', '学期')
    ].filter(Boolean);
    const cards = gridRows().map(row => ({
      title: row.kcmc || '未命名考试',
      subtitle: clean([row.ksmc, row.xnmc && `${row.xnmc}学年`, row.xqmmc && `第${row.xqmmc}学期`].filter(Boolean).join(' · ')),
      accent: row.kssj || '',
      fields: [
        {label: '考试时间', value: row.kssj},
        {label: '考试校区', value: row.cdxqmc || row.xqmc},
        {label: '考试地点', value: row.cdmc},
        {label: '座位号', value: row.zwh},
        {label: '考试方式', value: row.ksfs || row.khfs},
        {label: '课程代码', value: row.kch},
        {label: '教学班', value: row.jxbmc},
        {label: '开课学院', value: row.kkxy},
        {label: '备注', value: row.bzxx || row.ksbz}
      ].filter(field => field.value)
    }));
    const sections = cards.length
      ? [{type: 'cards', title: `共 ${cards.length} 场考试`, cards}]
      : [{type: 'text', title: '暂无考试', paragraphs: ['当前筛选条件没有考试安排。']}];
    return page('考试信息', sections, choices);
  }

  function programPage() {
    const choices = [selectChoice('#nj_cx', 'program-year', '年级', true)].filter(Boolean);
    const rows = gridRows();
    const modules = rows.map((row, index) => {
      const details = [
        ['专业代码', row.zyh],
        ['年级', row.njmc || row.njdm],
        ['校区', row.xqmc],
        ['课程数', row.kcs],
        ['最低毕业学分', row.zdxf],
        ['学制', row.xz],
        ['授予学位', row.syxw],
        ['专业方向数', row.zyfxgs],
        ['班级数', row.bjgs]
      ].filter(item => item[1]);
      return {
        id: row.jxzxjhxx_id || `program-${index}`,
        title: row.zymc || '教学执行计划',
        depth: 1,
        status: clean([row.njmc || row.njdm, row.xqmc].filter(Boolean).join('级 · ')),
        requirements: [
          row.zdxf && `最低毕业学分：${row.zdxf}`,
          row.kcs && `计划课程数：${row.kcs}`,
          row.xz && `学制：${row.xz}年`
        ].filter(Boolean),
        headers: ['项目', '内容'],
        courses: details,
        children: []
      };
    });
    const requiredCredits = rows.map(row => Number(row.zdxf)).filter(Number.isFinite).reduce((max, value) => Math.max(max, value), 0);
    return page('教学执行计划', [{
      type: 'program',
      title: '专业培养计划',
      requiredCredits: requiredCredits ? String(requiredCredits) : '',
      completedCredits: '',
      modules
    }], choices);
  }

  function read() {
    const path = location.pathname;
    if (path.includes('/kbcx/xskbcx_cxXskbcxIndex.html')) return schedulePage();
    if (path.includes('/cjcx/cjcx_cxDgXscj.html')) return gradePage();
    if (path.includes('/kwgl/kscx_cxXsksxxIndex.html')) return examPage();
    if (path.includes('/jxzxjhgl/jxzxjhck_cxJxzxjhckIndex.html')) return programPage();
    return page(document.title || '教务信息', [{
      type: 'text',
      title: '页面内容',
      paragraphs: [clean(document.body?.innerText) || '页面正在加载。']
    }]);
  }

  function setSelect(selector, value) {
    const element = document.querySelector(selector);
    if (!element) return false;
    element.value = String(value ?? '');
    element.dispatchEvent(new Event('change', {bubbles: true}));
    if (window.jQuery) {
      window.jQuery(element).trigger('chosen:updated');
      window.jQuery(element).trigger('chosen');
    }
    return true;
  }

  function queryAfterChange() {
    const button = document.querySelector('#search_go') || Array.from(document.querySelectorAll('button'))
      .find(item => clean(item.innerText) === '查询' && item.id !== 'kcSearch');
    if (button) button.click();
    setTimeout(publish, 150);
    setTimeout(publish, 700);
    setTimeout(publish, 1600);
  }

  function perform(actionId, value) {
    if (actionId === 'refresh') {
      location.reload();
      return true;
    }
    const selectors = {
      'schedule-year': '#xnm',
      'schedule-term': '#xqm',
      'grade-year': '#xnm',
      'grade-term': '#xqm',
      'exam-year': '#cx_xnm',
      'exam-term': '#cx_xqm',
      'program-year': '#nj_cx'
    };
    const selector = selectors[actionId];
    if (!selector || !setSelect(selector, value)) return false;
    queryAfterChange();
    return true;
  }

  let timer;
  let lastPayload = '';
  let autoQueryStarted = false;

  function maybeStartInitialQuery() {
    if (autoQueryStarted) return;
    const path = location.pathname;
    if (!path.includes('/cjcx/cjcx_cxDgXscj.html') && !path.includes('/kwgl/kscx_cxXsksxxIndex.html')) return;
    const button = document.querySelector('#search_go');
    if (!button) return;
    autoQueryStarted = true;
    button.click();
  }

  function publishNow() {
    try {
      maybeStartInitialQuery();
      const payload = read();
      const serialized = JSON.stringify(payload);
      if (serialized === lastPayload) return;
      window.PalmAcademicHost.publish(payload);
      lastPayload = serialized;
    } catch (error) {
      if (window.PalmAcademicHost.report) {
        window.PalmAcademicHost.report(`杭师大适配器读取失败：${error?.message || String(error)}`);
      }
    }
  }

  function publish() {
    clearTimeout(timer);
    timer = setTimeout(publishNow, 100);
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};

  function start() {
    if (!document.body) {
      setTimeout(start, 50);
      return;
    }
    new MutationObserver(publish).observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
    publishNow();
    setTimeout(publish, 500);
    setTimeout(publish, 1500);
  }

  start();
})();
