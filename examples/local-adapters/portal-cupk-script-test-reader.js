/* =========================================================================
 * CUPK 门户本地适配样例
 *
 * 同一文件包含两个互斥入口：网页中注册 PalmAcademicAdapter，登录沙箱中注册
 * PalmAcademicLoginAdapter。登录协议依据 cas.cupk.edu.cn 的实际表单：密码使用
 * RSA/PKCS#1，短信验证码由 /cas/v/getSMSCaptcha 发送。
 * ========================================================================= */

(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  function page() {
    return {
      title: document.title || 'CUPK 融合门户',
      sourceUrl: location.href,
      choices: [],
      actions: [{id: 'refresh', label: '刷新网页', value: ''}],
      sections: [{
        type: 'cards',
        title: '门户信息',
        cards: [{
          title: '当前页面',
          subtitle: '',
          fields: [{label: '地址', value: location.href}]
        }]
      }]
    };
  }

  function publish() { window.PalmAcademicHost.publish(page()); }
  function perform(actionId) {
    if (actionId !== 'refresh') return false;
    location.reload();
    return true;
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read: page, publish: publish, perform: perform};
  publish();
})();

(function () {
  'use strict';
  if (!window.PalmAcademic || window.PalmAcademicLoginAdapter) return;
  var H = window.PalmAcademic;
  var CAS = 'https://cas.cupk.edu.cn/cas';
  var SERVICE = 'https://portal.cupk.edu.cn/portal/';
  var LOGIN_URL = CAS + '/login?service=' + encodeURIComponent(SERVICE);
  var CAPTCHA_URL = CAS + '/captcha.jpg';
  var SUCCESS_PREFIX = 'https://portal.cupk.edu.cn/portal/';
  var PUBLIC_KEY =
    'MFswDQYJKoZIhvcNAQEBBQADSgAwRwJAUpCfX4kq+mbPNcVHM9x1OIwk94OaU4Dwt0gS0VHDM52pG60Fmxjm47DP5EXIgrg1UlMSwJbBIdHyg1XS1E3OjQIDAQAB';
  var HTML_HEADERS = {
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9'
  };
  var AJAX_HEADERS = {
    'Accept': 'application/json, text/javascript, */*; q=0.01',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'X-Requested-With': 'XMLHttpRequest'
  };

  function decodeEntities(value) {
    return String(value || '')
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;|&#x27;/gi, "'")
      .trim();
  }

  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function pickInput(html, key) {
    var name = escapeRegExp(key);
    var tag = String(html || '').match(new RegExp(
      '<input[^>]*(?:name|id)\\s*=\\s*["\\\']' + name + '["\\\'][^>]*>', 'i'
    ));
    if (!tag) return '';
    var value = tag[0].match(/value\s*=\s*["']([^"']*)["']/i);
    return value ? decodeEntities(value[1]) : '';
  }

  // 错误文案容器（#msg/#showErrorTip/#formErrorTip）内部常再套一层标签，
  // 截取元素片段后剥掉标签取纯文本。
  function extractError(html) {
    var source = String(html || '');
    var patterns = [
      /id=["']showErrorTip["'][^>]*>([\s\S]*?)<\/(?:span|div)>/i,
      /id=["']formErrorTip["'][^>]*>([\s\S]*?)<\/(?:span|div)>/i,
      /id=["']msg["'][^>]*>([\s\S]*?)<\/(?:span|div)>/i
    ];
    for (var i = 0; i < patterns.length; i++) {
      var block = source.match(patterns[i]);
      if (!block) continue;
      var text = decodeEntities(block[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' '));
      if (text) return text;
    }
    return '';
  }

  async function openLoginPage() {
    var response = await H.http({method: 'GET', url: LOGIN_URL, headers: HTML_HEADERS});
    var html = response.text || '';
    return {
      execution: pickInput(html, 'execution'),
      system: pickInput(html, 'system')
    };
  }

  function isSuccess(response) {
    return response.status >= 200 && response.status < 400 &&
      String(response.finalUrl || '').indexOf(SUCCESS_PREFIX) === 0;
  }

  function captchaChallenge(message) {
    return {
      ok: false,
      kind: 'captcha',
      message: message || '请输入图形验证码',
      captcha: {url: CAPTCHA_URL, refreshParam: 'id'}
    };
  }

  async function passwordLogin(values) {
    var page = await openLoginPage();
    if (!page.execution) {
      throw new Error('统一认证页缺少 execution，请稍后重试');
    }
    var encrypted = await H.crypto({
      op: 'rsa-pkcs1',
      data: values.password,
      publicKey: PUBLIC_KEY
    });
    var response = await H.http({
      method: 'POST',
      url: LOGIN_URL,
      headers: HTML_HEADERS,
      form: {
        username: values.username || '',
        password: encrypted,
        captcha: values.captcha || '',
        execution: page.execution,
        _eventId: 'submit',
        loginType: 'username',
        system: page.system,
        geolocation: ''
      }
    });
    if (isSuccess(response)) return {ok: true, kind: 'success'};
    var message = extractError(response.text) || '账号或密码错误';
    if (/验证码/.test(message)) return captchaChallenge(message);
    return {ok: false, kind: 'rejected', message: message};
  }

  async function smsLogin(values) {
    var page = await openLoginPage();
    if (!page.execution) {
      throw new Error('统一认证页缺少 execution，请稍后重试');
    }
    var response = await H.http({
      method: 'POST',
      url: LOGIN_URL,
      headers: HTML_HEADERS,
      form: {
        telphone: values.username || '',
        telphoneCaptcha: values.smsCode || '',
        execution: page.execution,
        _eventId: 'submit',
        loginType: 'telphone',
        system: page.system,
        geolocation: ''
      }
    });
    if (isSuccess(response)) return {ok: true, kind: 'success'};
    return {
      ok: false,
      kind: 'rejected',
      message: extractError(response.text) || '短信验证码登录失败，请检查后重试'
    };
  }

  window.PalmAcademicLoginAdapter = {
    describe: function () {
      return {
        methodSwitch: true,
        methods: [
          {
            id: 'password', kind: 'password', label: '账号密码', default: true,
            fields: [
              {id: 'username', type: 'text', label: '账号', required: true,
                placeholder: '请输入学号/工号'},
              {id: 'password', type: 'password', label: '密码', required: true,
                placeholder: '请输入密码'}
            ],
            checkboxes: [
              {id: 'rememberCredential', label: '记住密码', defaultChecked: true, scope: 'local'}
            ]
          },
          {
            id: 'sms', kind: 'sms', label: '短信登录',
            fields: [
              {id: 'username', type: 'tel', label: '手机号', required: true,
                placeholder: '请输入手机号'},
              {id: 'smsCode', type: 'smsCode', label: '短信验证码', required: true,
                placeholder: '请输入短信验证码'}
            ],
            checkboxes: []
          }
        ]
      };
    },

    submit: async function (arg) {
      var values = arg.values || {};
      return arg.methodId === 'sms' ? smsLogin(values) : passwordLogin(values);
    },

    sendSms: async function (arg) {
      var values = arg.values || {};
      if (!/^1\d{10}$/.test(values.username || '')) {
        return {ok: false, message: '请输入正确的 11 位手机号'};
      }
      // 先建立 CAS 预会话，确保短信接口与后续登录共用同一 cookie 罐。
      await openLoginPage();
      var response = await H.http({
        method: 'POST',
        url: CAS + '/v/getSMSCaptcha',
        headers: AJAX_HEADERS,
        form: {mobile: values.username}
      });
      var parsed = null;
      try { parsed = JSON.parse(response.text || ''); } catch (e) {}
      if (parsed && String(parsed.code) === '1') {
        return {ok: true, cooldownSeconds: 60, message: parsed.msg || '验证码已发送'};
      }
      return {ok: false, message: (parsed && parsed.msg) || '短信验证码发送失败'};
    }
  };
})();
