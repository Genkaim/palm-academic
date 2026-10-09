(function () {
  'use strict';

  // genkaim.top test school adapter.
  //
  // Web login lands on the CUPK fusion portal (CLIENT_USER_HOME); this script
  // only READS that single page and demonstrates the four native redraw
  // payloads from real, visible homepage data:
  //   schedule -> the three task boxes (todo / tracking / unread)
  //   grade    -> the "应用系统" carousel
  //   exam     -> the "网上服务" hall list
  //   program  -> the "常用服务" link list
  // No account/cookie/token data is read and nothing is ever submitted.
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();

  function requestedView() {
    const query = new URLSearchParams(location.search).get('paView');
    if (query) return query;
    const match = location.hash.match(/pa-(schedule|grade|exam|program)/);
    return match ? match[1] : 'schedule';
  }

  function page(title, sections) {
    return {
      title,
      sourceUrl: location.href,
      choices: [],
      actions: [{id: 'refresh', label: '刷新网页', value: ''}],
      sections
    };
  }

  const loading = title =>
    page(title, [{type: 'text', title: '正在读取', paragraphs: ['等待门户首页数据加载…']}]);

  // ---- schedule: 待办任务 / 跟踪任务 / 待阅任务 ---------------------------
  function taskPage() {
    const boxes = Array.from(document.querySelectorAll('.todoBox'));
    if (!boxes.length) return loading('任务概览');

    const lists = {
      '待办任务': '#todoList',
      '跟踪任务': '#truckList',
      '待阅任务': '#unReadList'
    };
    const counters = {
      '待办任务': '#todoCount',
      '跟踪任务': '#truckCount',
      '待阅任务': '#unReadCount'
    };
    const slotTimes = [
      ['08:00', '08:45'],
      ['08:50', '09:35'],
      ['10:00', '10:45']
    ];

    const days = boxes.slice(0, 3).map((box, index) => {
      const heading = box.querySelector('.todoTitle h3');
      const rawName = clean(heading ? heading.textContent : '').replace(/\(\d+\)$/, '').trim();
      const name = Object.keys(lists).find(key => rawName.includes(key))
        || rawName || `任务 ${index + 1}`;
      const count = clean(box.querySelector(counters[name] || '#todoCount'))
        .replace(/[()]/g, '') || '0';
      const items = Array.from(box.querySelectorAll(`${lists[name] || '#todoList'} li`))
        .map(li => clean(li.textContent))
        .filter(Boolean)
        .slice(0, 8);
      const [startTime, endTime] = slotTimes[index] || slotTimes[2];
      return {
        name,
        lessons: [{
          title: items.length ? items.join('；') : `${name}：${count} 项`,
          schedule: {
            weeks: '当前',
            startSection: String(index + 1),
            endSection: String(index + 1),
            teacher: '融合门户',
            location: `计数 ${count}`,
            startTime,
            endTime
          }
        }]
      };
    });

    return page('任务概览', [{
      type: 'schedule',
      title: '门户任务',
      semesterStartDate: new Date().toISOString().slice(0, 10),
      days
    }]);
  }

  // ---- grade: 应用系统 -----------------------------------------------------
  function applicationPage() {
    const links = Array.from(document.querySelectorAll('#thirdSystem .microserSort > a'));
    if (!links.length) return loading('应用系统');

    const seen = new Set();
    const cards = [];
    links.forEach(link => {
      const title = clean(link.querySelector('span') && link.querySelector('span').textContent);
      if (!title || seen.has(title)) return;
      seen.add(title);
      const badge = clean(link.querySelector('b') && link.querySelector('b').textContent);
      const target = link.getAttribute('url') || '';
      cards.push({
        title,
        subtitle: '融合门户应用',
        fields: [
          ...(badge && badge !== '0' ? [{label: '角标', value: badge}] : []),
          {label: '入口', value: target ? '门户跳转' : 'javascript'}
        ]
      });
    });

    return page('应用系统', [
      {type: 'cards', title: `应用系统（${cards.length}）`, cards}
    ]);
  }

  // ---- exam: 网上服务 ------------------------------------------------------
  function servicePage() {
    const items = Array.from(document.querySelectorAll('#hallList > li'));
    if (!items.length) return loading('网上服务');

    const cards = items.slice(0, 30).map(li => {
      const nameLink = li.querySelector('.caption a');
      const title = clean((nameLink && (nameLink.getAttribute('title') || nameLink.textContent)))
        || clean(li.textContent);
      const categories = Array.from(li.querySelectorAll('.mClass span'))
        .map(span => clean(span.textContent))
        .filter(Boolean);
      const used = clean(li.querySelector('.windom_free') &&
        li.querySelector('.windom_free').textContent);
      return {
        title,
        subtitle: categories.join(' · ') || '网上服务',
        fields: used ? [{label: '办理情况', value: used}] : []
      };
    }).filter(card => card.title);

    return page('网上服务', [
      {type: 'cards', title: `服务事项（${cards.length}）`, cards}
    ]);
  }

  // ---- program: 常用服务 ---------------------------------------------------
  function commonServicePage() {
    const links = Array.from(document.querySelectorAll('#resource.resourceUl > li > a'));
    if (!links.length) return loading('常用服务');

    const courses = links.map(link => {
      const name = clean((link.querySelector('span') && link.querySelector('span').textContent)
        || link.getAttribute('title'));
      const href = link.href || '';
      return name ? [name, href] : null;
    }).filter(Boolean);

    return page('常用服务', [{
      type: 'program',
      title: '常用服务',
      requiredCredits: '',
      completedCredits: '',
      modules: [{
        id: 'common-services',
        title: '常用服务',
        depth: 1,
        status: `${courses.length} 项`,
        requirements: ['数据来自登录后的融合门户首页“常用服务”'],
        headers: ['名称', '地址'],
        courses,
        children: []
      }]
    }]);
  }

  function read() {
    switch (requestedView()) {
      case 'grade': return applicationPage();
      case 'exam': return servicePage();
      case 'program': return commonServicePage();
      default: return taskPage();
    }
  }

  function perform(actionId) {
    if (actionId !== 'refresh') return false;
    location.reload();
    return true;
  }

  let timer = 0;
  let lastPayload = '';
  function publishNow() {
    const payload = read();
    const encoded = JSON.stringify(payload);
    if (encoded === lastPayload) return;
    window.PalmAcademicHost.publish(payload);
    lastPayload = encoded;
  }
  function publish() {
    clearTimeout(timer);
    timer = setTimeout(publishNow, 100);
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  if (document.body) {
    new MutationObserver(publish).observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
  }
  publishNow();
  setTimeout(publish, 500);
  setTimeout(publish, 1500);
})();
