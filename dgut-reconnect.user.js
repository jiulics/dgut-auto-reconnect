// ==UserScript==
// @name         DGUT 校园网持续认证助手（本地版）
// @namespace    local.dgut.reconnect
// @version      2.0.0
// @description  本地离线数字验证码识别、限次认证、后台联网验证；不读取或上传密码。
// @match        *://login.dgut.edu.cn/*
// @match        http://172.31.252.91:8080/eportal/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
// @noframes
// ==/UserScript==

(() => {
    'use strict';
    const validCode = text => /^[0-9]{4}$/.test(text);
    function fillCode(input, code, EventType = Event) {
        if (!validCode(code)) throw new Error('invalid_code');
        input.value = code;
        input.setAttribute('value', code);
        for (const name of ['input', 'change', 'blur']) input.dispatchEvent(new EventType(name, {bubbles:true}));
    }
    const maySubmit = ({paused, conflict, before, after}) => !paused && !conflict && before === after;
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = {validCode, fillCode, maySubmit}; return;
    }
    if (window.top !== window.self || document.getElementById('dgut-local-v2')) return;
    const panel = document.createElement('div');
    panel.id = 'dgut-local-v2';
    panel.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;background:#203047;color:white;padding:14px;border-radius:8px;font:14px sans-serif;max-width:360px';
    const status = document.createElement('div');
    const toggle = document.createElement('button');
    toggle.style.cssText = 'margin-top:10px;padding:4px 12px;cursor:pointer';
    panel.append(status, toggle); document.body.append(panel);
    let busy = false, lastEvent = '', lastImage = '';
    const visible = el => !!el && !!el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
    function rpc(path, data = {}) {
        return new Promise((resolve, reject) => GM_xmlhttpRequest({
            method:'POST', url:'http://127.0.0.1:18761' + path, timeout:15000,
            headers:{'Content-Type':'application/json','X-DGUT-Client':'local-v2'}, data:JSON.stringify(data),
            onload:r => { try { if (r.status !== 200) throw new Error('service_error'); resolve(JSON.parse(r.responseText)); } catch(e) { reject(e); } },
            onerror:()=>reject(new Error('service_offline')), ontimeout:()=>reject(new Error('service_timeout'))
        }));
    }
    function report(event) {
        if (event === lastEvent) return;
        lastEvent = event; rpc('/event', {event}).catch(()=>{});
    }
    function legacyConflict() {
        const old = document.getElementById('dgut-float-control');
        if (!old) return false;
        const button = old.querySelector('#toggle-pause-btn');
        if (button && button.textContent.trim() === '暂停') button.click();
        old.style.display = 'none';
        // Old script also has unconditional load-time clicks: refuse submission until disabled + reload.
        return true;
    }
    function pixels(img) {
        if (!img || !img.complete || !img.naturalWidth || img.naturalWidth > 1024 || img.naturalHeight > 512) throw new Error('image_not_ready');
        const canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth; canvas.height = img.naturalHeight;
        canvas.getContext('2d').drawImage(img, 0, 0);
        return canvas.toDataURL('image/png');
    }
    async function check() {
        if (busy) return;
        busy = true;
        try {
            const conflict = legacyConflict();
            const paused = GM_getValue('paused', false);
            toggle.textContent = paused ? '恢复自动认证' : '暂停自动认证';
            const net = await rpc('/state');
            if (conflict) {
                status.textContent = '检测到旧脚本：已暂停其定时循环并隐藏旧面板。请在油猴停用旧版后刷新；新版暂不提交。';
                report('legacy_conflict'); return;
            }
            if (paused) { status.textContent = '已暂停自动认证；后台继续检测'; report('paused'); return; }
            if (net.online === true) { status.textContent = '后台已验证联网正常，无需认证'; lastImage = ''; return; }
            if (net.online !== false) { status.textContent = '等待后台提供最新联网检测，暂不登录'; return; }
            const login = document.getElementById('loginLink');
            if (!visible(login) || login.disabled) { status.textContent = '等待可用登录按钮'; return; }
            const reserved = await rpc('/attempt');
            if (!reserved.allowed) { status.textContent = '等待重试：全局最多每15分钟3次，避免反复提交'; return; }
            const hasCaptcha = visible(document.getElementById('isDisplayValidCode'));
            let image, before;
            if (hasCaptcha) {
                image = document.getElementById('validImage');
                before = pixels(image);
                if (before === lastImage) {
                    image.click(); report('stale_image');
                    status.textContent = '上一张验证码已提交，等待页面更新验证码'; return;
                }
                status.textContent = '正在本机识别验证码，不上传账号密码';
                const result = await rpc('/ocr', {image:before});
                if (!validCode(result.code)) throw new Error('invalid_code');
                if (!maySubmit({paused:GM_getValue('paused',false),conflict:legacyConflict(),before,after:pixels(image)})) {
                    report('stale_image'); status.textContent = '验证码已变化或已暂停，本次不提交'; return;
                }
                const input = document.getElementById('validCode');
                if (!input) throw new Error('missing_input');
                const tip = document.getElementById('validCode_tip');
                if (tip) tip.style.display = 'none';
                input.style.display = '';
                fillCode(input, result.code);
            }
            if (GM_getValue('paused', false) || legacyConflict()) return;
            if ((await rpc('/state')).online !== false) return;
            if (GM_getValue('paused',false) || legacyConflict()) return;
            if (!hasCaptcha && visible(document.getElementById('isDisplayValidCode'))) return;
            if (hasCaptcha && pixels(image) !== before) { report('stale_image'); return; }
            if (!visible(login) || login.disabled) return;
            login.click(); lastImage = before || '';
            report('submitted'); status.textContent = '已提交认证，等待后台验证联网结果';
        } catch (error) {
            status.textContent = '本次未完成：请检查本地OCR服务/验证码图片；不会空填验证码提交。详情见 ocr.log';
            report('ocr_failed');
        } finally { busy = false; }
    }
    toggle.addEventListener('click', () => { GM_setValue('paused', !GM_getValue('paused',false)); check(); });
    async function tick() { try { await check(); } finally { setTimeout(tick, 5000); } }
    setTimeout(tick, 5000);
})();
