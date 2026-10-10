(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const view = () => new URLSearchParams(location.search).get('paView') || 'schedule';
  const links = () => Array.from(document.querySelectorAll('a'))
    .map(a => ({title: clean(a.textContent || a.title), href: a.href || ''}))
    .filter(item => item.title && item.href && !item.href.startsWith('javascript:'))
    .slice(0, 12);
  const page = (title, sections) => ({
    title,
    sourceUrl: location.href,
    choices: [],
    actions: [{id: 'refresh', label: '刷新网页', value: ''}],
    sections
  });

  function read() {
    const items = links();
    if (view() === 'schedule') {
      return page('门户概览', [{
        type: 'schedule',
        title: '门户快捷入口',
        semesterStartDate: new Date().toISOString().slice(0, 10),
        days: [{
          name: '当前页面',
          lessons: (items.length ? items : [{title: '融合门户', href: location.href}]).slice(0, 3)
            .map((item, index) => ({
              title: item.title,
              schedule: {
                weeks: '当前',
                startSection: String(index + 1),
                endSection: String(index + 1),
                teacher: '融合门户',
                location: 'portal.cupk.edu.cn',
                startTime: ['09:30', '10:20', '11:25'][index],
                endTime: ['10:15', '11:05', '12:10'][index]
              }
            }))
        }]
      }]);
    }
    if (view() === 'program') {
      const rows = (items.length ? items : [{title: '融合门户首页', href: location.href}])
        .map(item => [item.title, item.href]);
      return page('常用功能', [{
        type: 'program',
        title: '常用功能',
        requiredCredits: '',
        completedCredits: '',
        modules: [{
          id: 'portal-links', title: '页面链接', depth: 1, status: `${rows.length} 项`,
          requirements: ['测试适配器只读取当前门户页面的可见链接'],
          headers: ['名称', '地址'], courses: rows, children: []
        }]
      }]);
    }
    const cards = (items.length ? items : [{title: '融合门户首页', href: location.href}])
      .map(item => ({
        title: item.title,
        subtitle: view() === 'grade' ? '应用入口' : '网上服务',
        fields: [{label: '地址', value: item.href}]
      }));
    return page(view() === 'grade' ? '应用入口' : '网上服务', [
      {type: 'cards', title: `已读取 ${cards.length} 项`, cards}
    ]);
  }

  function publish() { window.PalmAcademicHost.publish(read()); }
  function perform(actionId) {
    if (actionId !== 'refresh') return false;
    location.reload();
    return true;
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  publish();
  if (document.body) {
    let timer;
    new MutationObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(publish, 150);
    }).observe(document.body, {childList: true, subtree: true, characterData: true});
  }
})();
