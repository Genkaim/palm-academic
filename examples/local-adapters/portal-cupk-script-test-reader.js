/* =========================================================================
 * portal-cupk-script-test —— 掌上门户【脚本登录全方式】测试样例
 *
 * 用途：演示/测试 type=script 学校的登录沙箱能力，一份脚本声明三种登录方式：
 *   1. 账号密码（AES-CBC-PKCS7 密码加密 + 可选图形验证码）
 *   2. 手机短信（常驻图形验证码 + 短信倒计时）
 *   3. APP 扫码（二维码下发 / 已扫码 / 失效重取 / 轮询）
 * 并演示 local / request 两种作用域的复选框，以及 methodSwitch 显式声明。
 *
 * 约定（与内置 hznu-reader.js 登录段一致）：
 *  - 文件前半段是网页重绘适配器（仅在带 window.PalmAcademicHost 的 WebView 中运行）；
 *  - 文件后半段是登录适配器（仅在 App 的 JS 沙箱中运行，沙箱无 DOM、无网络对象，
 *    只能通过 window.PalmAcademic.{http,crypto,sleep,ui} 与原生通信）；
 *  - 两段互斥，按宿主环境自行早退。
 *
 * 注意：本样例的所有接口地址都落在 https://portal.cupk.edu.cn 主机上（沙箱白名单
 * 由学校 JSON 的 loginUrl/baseUrl/successUrlPrefixes/sessionCookieHosts 推导），
 * 其中 /portal/api/login/* 为占位接口，用于走通界面与沙箱链路；接入真实学校时，
 * 把 openLoginPage / passwordLogin / sendSms / smsLogin / qrLogin 里的地址、
 * 表单字段和成功/失败判定替换为抓包得到的真实协议即可。
 * ========================================================================= */

/* -------------------------------------------------------------------------
 * 一、网页重绘适配器（最小样例：把门户首页包成一个静态说明页）
 * ------------------------------------------------------------------------- */
(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  function clean(value) {
    return String(value || '')
      .replace(/\u00a0/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function buildPage() {
    return {
      title: '脚本登录测试样例',
      sourceUrl: location.href,
      choices: [],
      actions: [{ id: 'refresh', label: '刷新网页', value: '' }],
      sections: [
        {
          id: 'about',
          title: '关于本样例',
          items: [
            { label: '登录方式', value: '账号密码 / 短信 / 扫码' },
            { label: '切换菜单', value: '由 describe() 的 methodSwitch:true 显式开启' },
            { label: '密码通道', value: '占位符 __PA_PASSWORD__，明文不进入 JS' }
          ]
        }
      ]
    };
  }

  window.PalmAcademicAdapter = {
    apiVersion: 1,
    read: function () { return buildPage(); },
    publish: function () {
      var host = window.PalmAcademicHost;
      if (host && typeof host.publish === 'function') host.publish(buildPage());
    },
    perform: function () {}
  };

  window.PalmAcademicAdapter.publish();
})();

/* -------------------------------------------------------------------------
 * 二、登录适配器（仅运行于 App 沙箱；没有 DOM，只能使用 window.PalmAcademic）
 * ------------------------------------------------------------------------- */
(function () {
  if (!window.PalmAcademic || window.PalmAcademicLoginAdapter) return;
  var H = window.PalmAcademic;

  // 全部接口都在学校白名单主机 portal.cupk.edu.cn 之上（仅 https）。
  var PORTAL = 'https://portal.cupk.edu.cn/portal';
  var LOGIN_PAGE = PORTAL + '/login';
  var API = PORTAL + '/api/login';
  var CAPTCHA_URL = PORTAL + '/api/captcha/image';
  var SUCCESS_PREFIX = 'https://portal.cupk.edu.cn/portal/home';

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

  // 从登录页 HTML 中取 hidden input 的 value。
  function pickInput(html, id) {
    var tagMatch = html.match(new RegExp('<input[^>]*id=["\']' + id + '["\'][^>]*>', 'i'));
    if (!tagMatch) return '';
    var valueMatch = tagMatch[0].match(/value=["']([^"']*)["']/i);
    return valueMatch ? decodeEntities(valueMatch[1]) : '';
  }

  function extractError(html) {
    var patterns = [
      /id=["']msg["'][^>]*>\s*([^<]+?)\s*</i,
      /class=["'][^"']*auth_error[^"']*["'][^>]*>\s*([^<]+?)\s*</i
    ];
    for (var i = 0; i < patterns.length; i++) {
      var m = html.match(patterns[i]);
      if (m && decodeEntities(m[1])) return decodeEntities(m[1]);
    }
    return '';
  }

  function parseJSON(text) {
    try { return JSON.parse(text || ''); } catch (e) { return null; }
  }

  function isSuccess(resp) {
    var url = resp.finalUrl || '';
    return resp.status >= 200 && resp.status < 400 &&
      url.indexOf(SUCCESS_PREFIX) === 0;
  }

  function captchaChallenge(message) {
    return {
      ok: false, kind: 'captcha', message: message || '需要输入图形验证码',
      captcha: { url: CAPTCHA_URL, refreshParam: 'ts' }
    };
  }

  // 拉取登录页：建立预会话 cookie，并尝试取密码加密盐与 execution token。
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
        url: PORTAL + '/api/captcha/need?username=' + encodeURIComponent(username || ''),
        headers: AJAX_HEADERS
      });
      return /"isNeed"\s*:\s*true/i.test(resp.text || '');
    } catch (e) {
      return false; // 探测失败不阻塞：服务端仍可在提交结果里要求验证码
    }
  }

  // 演示 crypto 桥：服务端给 salt 时走 AES-CBC-PKCS7（明文前拼 64 个随机字符，
  // IV 自生），否则退化为 sha1 摘要。密码在原生边界替换占位符，明文不进入 JS。
  async function encryptPassword(page) {
    if (page.salt) {
      return await H.crypto({
        op: 'aes-cbc-pkcs7', key: page.salt, data: '__PA_PASSWORD__', prefixLength: 64
      });
    }
    return await H.crypto({ op: 'sha1', data: '__PA_PASSWORD__' });
  }

  async function passwordLogin(v, checks) {
    var page = await openLoginPage();

    // schema 里声明了常驻图形验证码字段；同时兼容脚本动态要求验证码的协议。
    if ((v.captcha ? false : await needCaptcha(v.username))) {
      return captchaChallenge('该账号需要输入图形验证码');
    }

    var encrypted = await encryptPassword(page);
    var resp = await H.http({
      method: 'POST', url: API + '/password', headers: BROWSER_HEADERS,
      form: {
        username: v.username || '',
        password: encrypted,
        captcha: v.captcha || '',
        execution: page.execution,
        lt: page.lt,
        _eventId: 'submit',
        rememberMe: checks.remember7Days ? 'true' : 'false',
        agreement: checks.loginAgreement ? 'true' : 'false'
      }
    });
    if (isSuccess(resp)) return { ok: true, kind: 'success' };

    // 占位接口也可能直接返回 JSON 判定。
    var parsed = parseJSON(resp.text);
    if (parsed) {
      if (parsed.code === 'success') return { ok: true, kind: 'success' };
      if (parsed.code === 'captcha') {
        return captchaChallenge(parsed.message || '需要输入图形验证码');
      }
      if (parsed.message) return { ok: false, kind: 'rejected', message: parsed.message };
    }
    var message = extractError(resp.text) || '账号或密码错误';
    if (/验证码/.test(message)) return captchaChallenge(message);
    return { ok: false, kind: 'rejected', message: message };
  }

  async function smsLogin(v) {
    var page = await openLoginPage();
    var resp = await H.http({
      method: 'POST', url: API + '/sms', headers: BROWSER_HEADERS,
      form: {
        username: v.username || '',
        captcha: v.captcha || '',
        dynamicCode: v.smsCode || '',
        execution: page.execution,
        lt: page.lt
      }
    });
    if (isSuccess(resp)) return { ok: true, kind: 'success' };
    var parsed = parseJSON(resp.text);
    if (parsed && parsed.code === 'success') return { ok: true, kind: 'success' };
    var message = (parsed && parsed.message)
      || extractError(resp.text)
      || '短信验证登录失败，请检查后重试';
    if (/验证码/.test(message)) message += '，请点击图形验证码更换后重试';
    // 统一失败策略：短信方式的确定性失败弹“登录失败”模态框。
    return { ok: false, kind: 'rejected', message: message };
  }

  async function fetchToken(uuid) {
    var url = API + '/qr/token?ts=' + Date.now();
    if (uuid) url += '&uuid=' + encodeURIComponent(uuid);
    var resp = await H.http({ method: 'GET', url: url, headers: AJAX_HEADERS });
    return (resp.text || '').trim().replace(/^"|"$/g, '');
  }

  function showQr(uuid, state, message) {
    return H.ui({
      type: 'qr', state: state, message: message,
      imageUrl: API + '/qr/image?uuid=' + encodeURIComponent(uuid)
    });
  }

  async function qrLogin() {
    await H.http({ method: 'GET', url: LOGIN_PAGE, headers: BROWSER_HEADERS });
    var uuid = await fetchToken('');
    if (!uuid) throw new Error('二维码服务未响应');
    await showQr(uuid, 'waiting', '请使用学校 APP 或微信扫码登录');

    var networkErrors = 0;
    while (true) {
      await H.sleep(1500);
      var statusText = '';
      try {
        var statusResp = await H.http({
          method: 'GET',
          url: API + '/qr/status?ts=' + Date.now() + '&uuid=' + encodeURIComponent(uuid),
          headers: AJAX_HEADERS
        });
        if (statusResp.status < 200 || statusResp.status >= 300) {
          throw new Error('二维码状态服务异常（HTTP ' + statusResp.status + '）');
        }
        statusText = (statusResp.text || '').trim();
        networkErrors = 0;
      } catch (e) {
        // 轮询偶发失败不打断登录；连续约 30 秒失败则抛给原生整体重试（无限重试）。
        networkErrors += 1;
        if (networkErrors >= 20) throw e;
        continue;
      }

      // 状态约定（与金智扫码一致）：2=已扫码待确认，3=二维码失效，1=已确认。
      if (statusText === '2') {
        await H.ui({ type: 'qr', state: 'scanned', message: '已扫码，请在手机上确认' });
      } else if (statusText === '3') {
        uuid = await fetchToken('');
        if (!uuid) throw new Error('二维码刷新失败');
        await showQr(uuid, 'waiting', '二维码已刷新，请重新扫码');
      } else if (statusText === '1') {
        var resp = await H.http({
          method: 'POST', url: API + '/qr/confirm', headers: BROWSER_HEADERS,
          form: {
            uuid: uuid, execution: 'e1s1', _eventId: 'submit', cllt: 'qrLogin'
          }
        });
        if (isSuccess(resp)) return { ok: true, kind: 'success' };
        var parsed = parseJSON(resp.text);
        if (parsed && parsed.code === 'success') return { ok: true, kind: 'success' };
        return {
          ok: false, kind: 'rejected',
          message: (parsed && parsed.message) || '扫码登录失败，请重试'
        };
      }
    }
  }

  window.PalmAcademicLoginAdapter = {
    describe: function () {
      return {
        // 必须显式声明 methodSwitch:true，原生界面才渲染三方式切换菜单。
        methodSwitch: true,
        methods: [
          {
            id: 'password', kind: 'password', label: '账号密码', default: true,
            fields: [
              { id: 'username', type: 'text', label: '学号/工号', required: true,
                placeholder: '请输入学号/工号' },
              { id: 'password', type: 'password', label: '密码', required: true,
                placeholder: '请输入密码' },
              // 常驻图形验证码字段：尾部图片由原生经白名单 https 拉取，
              // refreshParam 指定刷新时自动追加毫秒时间戳的查询参数。
              { id: 'captcha', type: 'captcha', label: '图形验证码', required: false,
                placeholder: '看不清可点击图片刷新',
                captcha: { url: CAPTCHA_URL, refreshParam: 'ts' } }
            ],
            checkboxes: [
              // local：原生侧把账号密码保存到钥匙串/Keystore，下次自动回填，不随表单提交。
              { id: 'rememberCredential', label: '记住密码', defaultChecked: true, scope: 'local' },
              // request：学校侧“7 天内免登录”，作为表单 rememberMe 提交，与保存密码互不影响。
              { id: 'remember7Days', label: '7天内免登录', defaultChecked: true, scope: 'request' },
              // request：另一个随表单提交的协议复选框（登录须知）。
              { id: 'loginAgreement', label: '我已阅读登录须知', defaultChecked: false, scope: 'request' }
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
              // smsCode 字段会自动获得“获取验证码 / Ns 后重发”尾部按钮。
              { id: 'smsCode', type: 'smsCode', label: '短信验证码', required: true,
                placeholder: '请输入短信验证码' }
            ],
            // 短信/扫码方式没有密码，不提供 rememberCredential（原生仅在密码方式保存密码）。
            checkboxes: []
          },
          {
            id: 'qrcode', kind: 'qrcode', label: '扫码登录',
            fields: [],
            checkboxes: []
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

    // 发送短信动态码；返回 {ok,message,cooldownSeconds}，cooldownSeconds 驱动原生倒计时。
    sendSms: async function (arg) {
      var v = arg.values || {};
      if (!v.username) return { ok: false, message: '请先输入手机号/学号' };
      if (!v.captcha) return { ok: false, message: '请先输入图形验证码' };
      var resp = await H.http({
        method: 'POST',
        url: API + '/sms/send',
        headers: AJAX_HEADERS,
        form: { username: v.username, captcha: v.captcha }
      });
      var parsed = parseJSON(resp.text);
      if (!parsed) return { ok: false, message: '短信服务无响应，请稍后重试' };
      if (parsed.code === 'success') {
        return {
          ok: true,
          cooldownSeconds: Number(parsed.intervalTime) || 60,
          message: parsed.message || '验证码已发送'
        };
      }
      return { ok: false, message: parsed.message || '短信验证码发送失败' };
    }
  };
})();
