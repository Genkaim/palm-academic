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

/* =========================================================================
 * 登录适配器（杭州师范大学 金智 wisedu 统一认证）
 * 仅在 App 登录沙箱中运行；与文件开头的重绘适配器互斥（沙箱只提供
 * window.PalmAcademic，不提供 PalmAcademicHost）。
 * 三种方式：账号密码（AES-CBC + 可选图形验证码）、手机短信、APP 扫码。
 * ========================================================================= */
(function () {
  if (!window.PalmAcademic || window.PalmAcademicLoginAdapter) return;
  var H = window.PalmAcademic;

  var AUTH = 'https://authserver.hznu.edu.cn/authserver';
  var SERVICE = 'https://jwxt.hznu.edu.cn/sso/jznewsixlogin';
  var LOGIN_PAGE = AUTH + '/login?service=' + encodeURIComponent(SERVICE);
  var LOGIN_ACTION = AUTH + '/login?service=' + encodeURIComponent(SERVICE);
  var QR_ACTION = AUTH + '/login?display=qrLogin&service=' + encodeURIComponent(SERVICE);
  var CAPTCHA_URL = AUTH + '/getCaptcha.htl';
  // 与 login.js 中硬编码的 DEFAULT_SALT 保持一致（用于手机号加密）。
  var DEFAULT_SALT = 'rjBFAaHsNkKAhpoi';
  var BROWSER_HEADERS = {
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Upgrade-Insecure-Requests': '1'
  };
  var AJAX_HEADERS = {
    'Accept': 'application/json, text/javascript, */*; q=0.01',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'X-Requested-With': 'XMLHttpRequest'
  };
  var SUCCESS_PREFIXES = [
    'https://jwxt.hznu.edu.cn/jwglxt/',
    'https://jwxt.hznu.edu.cn/sso/'
  ];

  function decodeEntities(value) {
    return String(value || '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .trim();
  }

  // 从登录页 HTML 中取 hidden input 的 value（属性顺序不固定，同名 id 取第一个）。
  function pickInput(html, id) {
    var tagMatch = html.match(new RegExp('<input[^>]*id=["\']' + id + '["\'][^>]*>', 'i'));
    if (!tagMatch) return '';
    var valueMatch = tagMatch[0].match(/value=["']([^"']*)["']/i);
    return valueMatch ? decodeEntities(valueMatch[1]) : '';
  }

  // 失败页中的错误文案：新版主题写入 #showErrorTip，老版在 #msg/.auth_error。
  function extractError(html) {
    var patterns = [
      /id=["']msg["'][^>]*>\s*([^<]+?)\s*</i,
      /id=["']showErrorTip["'][^>]*>\s*([^<]+?)\s*</i,
      /class=["'][^"']*auth_error[^"']*["'][^>]*>\s*([^<]+?)\s*</i
    ];
    for (var i = 0; i < patterns.length; i++) {
      var m = html.match(patterns[i]);
      if (m && decodeEntities(m[1])) return decodeEntities(m[1]);
    }
    return '';
  }

  function isSuccess(resp) {
    var url = resp.finalUrl || '';
    return resp.status >= 200 && resp.status < 400 &&
      SUCCESS_PREFIXES.some(function (prefix) { return url.indexOf(prefix) === 0; });
  }

  function captchaChallenge(message) {
    return {
      ok: false, kind: 'captcha', message: message || '需要输入图形验证码',
      captcha: { url: CAPTCHA_URL, refreshParam: 'ts' }
    };
  }

  // 拉取登录页并解析 hidden 字段；同时建立 authserver 预会话。
  async function openLoginPage() {
    var resp = await H.http({ method: 'GET', url: LOGIN_PAGE, headers: BROWSER_HEADERS });
    var html = resp.text || '';
    return {
      html: html,
      salt: pickInput(html, 'pwdEncryptSalt'),
      execution: pickInput(html, 'execution') || 'e1s1',
      lt: pickInput(html, 'lt')
    };
  }

  async function needCaptcha(username) {
    try {
      var resp = await H.http({
        method: 'GET',
        url: AUTH + '/checkNeedCaptcha.htl?username=' + encodeURIComponent(username || ''),
        headers: AJAX_HEADERS
      });
      return /"isNeed"\s*:\s*true/i.test(resp.text || '');
    } catch (e) {
      return false; // 探测失败不阻塞：真需要时服务端会在提交结果里返回验证码错误
    }
  }

  async function passwordLogin(v, checks) {
    var page = await openLoginPage();
    if (!page.salt) return { ok: false, kind: 'rejected', message: '未能加载登录所需信息，请重试' };

    if ((await needCaptcha(v.username)) && !v.captcha) {
      return captchaChallenge('该账号需要输入图形验证码');
    }

    // 金智 encryptPassword：AES-CBC-PKCS7，key=UTF8(salt)，明文前拼 64 个随机字符，
    // IV 随机（密文不携带 IV，前 4 个随机分组吸收 IV 差异）。原生侧实现等价算法。
    var encrypted = await H.crypto({
      op: 'aes-cbc-pkcs7', key: page.salt, data: v.password, prefixLength: 64
    });

    var resp = await H.http({
      method: 'POST', url: LOGIN_ACTION, headers: BROWSER_HEADERS,
      form: {
        username: v.username || '',
        password: encrypted,
        captcha: v.captcha || '',
        _eventId: 'submit',
        cllt: 'userNameLogin',
        dllt: 'generalLogin',
        lt: page.lt,
        execution: page.execution,
        rememberMe: checks.rememberCredential ? 'true' : 'false'
      }
    });
    if (isSuccess(resp)) return { ok: true, kind: 'success' };

    var message = extractError(resp.text || '') || '账号或密码错误';
    if (/验证码/.test(message)) return captchaChallenge(message);
    return { ok: false, kind: 'rejected', message: message };
  }

  async function smsLogin(v) {
    var page = await openLoginPage();
    var resp = await H.http({
      method: 'POST', url: LOGIN_ACTION, headers: BROWSER_HEADERS,
      form: {
        username: v.username || '',
        captcha: v.captcha || '',
        dynamicCode: v.smsCode || '',
        _eventId: 'submit',
        cllt: 'dynamicLogin',
        dllt: 'generalLogin',
        lt: page.lt,
        execution: page.execution
      }
    });
    if (isSuccess(resp)) return { ok: true, kind: 'success' };
    var message = extractError(resp.text || '') || '短信验证登录失败，请检查后重试';
    // 图形验证码一次性使用：提示用户换一张再登录。
    if (/验证码/.test(message)) message += '，请点击图形验证码更换后重试';
    return { ok: false, kind: 'rejected', message: message };
  }

  async function fetchToken(uuid) {
    var url = AUTH + '/qrCode/getToken?ts=' + Date.now();
    if (uuid) url += '&uuid=' + encodeURIComponent(uuid);
    var resp = await H.http({ method: 'GET', url: url, headers: AJAX_HEADERS });
    return (resp.text || '').trim().replace(/^"|"$/g, '');
  }

  function showQr(uuid, state, message) {
    return H.ui({
      type: 'qr', state: state, message: message,
      imageUrl: AUTH + '/qrCode/getCode?uuid=' + encodeURIComponent(uuid)
    });
  }

  async function qrLogin() {
    await H.http({ method: 'GET', url: LOGIN_PAGE, headers: BROWSER_HEADERS });
    var uuid = await fetchToken('');
    if (!uuid) throw new Error('二维码服务未响应');
    await showQr(uuid, 'waiting', '请使用杭州师范大学 APP 扫码登录');

    var networkErrors = 0;
    while (true) {
      await H.sleep(1500);
      var statusText = '';
      try {
        var statusResp = await H.http({
          method: 'GET',
          url: AUTH + '/qrCode/getStatus.htl?ts=' + Date.now() + '&uuid=' + encodeURIComponent(uuid),
          headers: AJAX_HEADERS
        });
        statusText = (statusResp.text || '').trim();
        networkErrors = 0;
      } catch (e) {
        // 轮询偶发失败不打断登录；连续约 30 秒失败则交给原生整体重试。
        networkErrors += 1;
        if (networkErrors >= 20) throw e;
        continue;
      }

      if (statusText === '2') {
        await H.ui({ type: 'qr', state: 'scanned', message: '已扫码，请在手机上确认' });
      } else if (statusText === '3') {
        uuid = await fetchToken('');
        if (!uuid) throw new Error('二维码刷新失败');
        await showQr(uuid, 'waiting', '二维码已刷新，请重新扫码');
      } else if (statusText === '1') {
        var resp = await H.http({
          method: 'POST', url: QR_ACTION, headers: BROWSER_HEADERS,
          form: {
            lt: '',
            uuid: uuid,
            cllt: 'qrLogin',
            dllt: 'generalLogin',
            execution: 'e1s1',
            _eventId: 'submit',
            rmShown: '1'
          }
        });
        if (isSuccess(resp)) return { ok: true, kind: 'success' };
        return { ok: false, kind: 'rejected', message: '扫码登录失败，请重试' };
      }
    }
  }

  window.PalmAcademicLoginAdapter = {
    describe: function () {
      return {
        methods: [
          {
            id: 'password', kind: 'password', label: '账号密码', default: true,
            fields: [
              { id: 'username', type: 'text', label: '学号/工号', required: true,
                placeholder: '请输入学号/工号' },
              { id: 'password', type: 'password', label: '密码', required: true,
                placeholder: '请输入密码' }
            ],
            checkboxes: [
              // request 作用域：同时作为表单 rememberMe 提交（7 天免登录）。
              { id: 'rememberCredential', label: '7天内免登录', defaultChecked: true, scope: 'request' }
            ]
          },
          {
            id: 'sms', kind: 'sms', label: '短信登录',
            fields: [
              { id: 'username', type: 'tel', label: '手机号/学号', required: true,
                placeholder: '请输入手机号/学号' },
              { id: 'captcha', type: 'captcha', label: '图形验证码', required: true,
                placeholder: '请输入图形验证码',
                captcha: { url: CAPTCHA_URL, refreshParam: 'ts' } },
              { id: 'smsCode', type: 'smsCode', label: '短信验证码', required: true,
                placeholder: '请输入短信验证码' }
            ],
            checkboxes: []
          },
          {
            id: 'qrcode', kind: 'qrcode', label: '扫码登录',
            fields: [], checkboxes: []
          }
        ]
      };
    },

    submit: async function (arg) {
      var v = arg.values || {};
      var checks = arg.checkboxes || {};
      if (arg.methodId === 'sms') return await smsLogin(v);
      if (arg.methodId === 'qrcode') return await qrLogin();
      return await passwordLogin(v, checks);
    },

    // 发送短信动态码：手机号按金智规则用 DEFAULT_SALT 做 AES 加密。
    sendSms: async function (arg) {
      var v = arg.values || {};
      if (!v.username) return { ok: false, message: '请先输入手机号/学号' };
      if (!v.captcha) return { ok: false, message: '请先输入图形验证码' };
      var mobile = await H.crypto({
        op: 'aes-cbc-pkcs7', key: DEFAULT_SALT, data: v.username, prefixLength: 64
      });
      var resp = await H.http({
        method: 'POST',
        url: AUTH + '/dynamicCode/getDynamicCode.htl',
        headers: AJAX_HEADERS,
        form: { mobile: mobile, captcha: v.captcha || '' }
      });
      var parsed = null;
      try { parsed = JSON.parse(resp.text || ''); } catch (e) {}
      if (!parsed) return { ok: false, message: '短信服务无响应，请稍后重试' };
      if (parsed.code === 'success') {
        return {
          ok: true,
          cooldownSeconds: Number(parsed.intervalTime) || 120,
          message: parsed.message || '验证码已发送'
        };
      }
      return { ok: false, message: parsed.message || '短信验证码发送失败' };
    }
  };
})();
