import fs from 'fs';
import path from 'path';
import { execFile } from 'child_process';
import ffmpegPath from 'ffmpeg-static';
import { chromium } from 'playwright-extra';
import StealthPlugin from 'puppeteer-extra-plugin-stealth';

// Apply Playwright stealth plugin for Auth0 / Cloudflare bypass
chromium.use(StealthPlugin());

// Token Cache File
const TOKEN_CACHE_FILE = path.join(process.cwd(), '.stable_audio_token');

// Utility sleep
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Load Token from env, cache file, or memory
function getStoredToken() {
  if (process.env.STABLE_AUDIO_TOKEN) {
    return process.env.STABLE_AUDIO_TOKEN.trim();
  }
  if (fs.existsSync(TOKEN_CACHE_FILE)) {
    try {
      const cached = fs.readFileSync(TOKEN_CACHE_FILE, 'utf8').trim();
      if (cached && cached.length > 50) return cached;
    } catch {}
  }
  return null;
}

function saveStoredToken(token) {
  try {
    fs.writeFileSync(TOKEN_CACHE_FILE, token, 'utf8');
  } catch (err) {
    console.warn(`[Warning] Could not cache token to file: ${err.message}`);
  }
}

let currentToken = getStoredToken();

// ─── CREDENTIAL GENERATORS ────────────────────────────────────────────────
function generateRandomEmail() {
  const ts = Date.now();
  const rnd = Math.random().toString(36).substring(2, 10);
  const domains = ['gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com'];
  const domain = domains[Math.floor(Math.random() * domains.length)];
  return `stableaudio_${rnd}_${ts}@${domain}`;
}

function generateStrongPassword() {
  const lc = 'abcdefghijklmnopqrstuvwxyz';
  const uc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const num = '0123456789';
  const sp = '!@#$%^&*';
  let pw = '';
  pw += lc[Math.floor(Math.random() * lc.length)];
  pw += lc[Math.floor(Math.random() * lc.length)];
  pw += uc[Math.floor(Math.random() * uc.length)];
  pw += uc[Math.floor(Math.random() * uc.length)];
  pw += num[Math.floor(Math.random() * num.length)];
  pw += num[Math.floor(Math.random() * num.length)];
  pw += sp[Math.floor(Math.random() * sp.length)];
  pw += sp[Math.floor(Math.random() * sp.length)];
  const all = lc + uc + num + sp;
  for (let i = 0; i < 4; i++) pw += all[Math.floor(Math.random() * all.length)];
  return pw.split('').sort(() => Math.random() - 0.5).join('');
}

// ─── AUTO ACCOUNT CREATION & AUTH0 BYPASS ────────────────────────────────
async function createStableAudioAccount(headless = true) {
  const email = generateRandomEmail();
  const password = generateStrongPassword();

  console.log('\n🤖 AUTO ACCOUNT CREATION & TOKEN PROVISIONING');
  console.log(`📧 Email   : ${email}`);
  console.log(`🔑 Password: ${password}`);

  const browser = await chromium.launch({
    headless: headless,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-blink-features=AutomationControlled'
    ]
  });

  let capturedToken = null;

  try {
    const context = await browser.newContext({
      userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    });
    const page = await context.newPage();

    // Network request listener for Bearer token sniffing
    page.on('request', (req) => {
      const auth = req.headers()['authorization'];
      if (auth && auth.startsWith('Bearer ') && req.url().includes('stableaudio.com')) {
        const tok = auth.replace('Bearer ', '').trim();
        if (tok.length > 50) {
          capturedToken = tok;
          console.log('🔑 Token captured from network request!');
        }
      }
    });

    // Sniff /oauth/token response
    page.on('response', async (resp) => {
      try {
        const url = resp.url();
        const isTokenEndpoint =
          url.includes('/oauth/token') ||
          url.includes('/token') ||
          url.includes('auth0') ||
          url.includes('login.stableaudio');
        if (isTokenEndpoint && resp.status() === 200) {
          const json = await resp.json().catch(() => null);
          if (json && (json.access_token || json.id_token)) {
            capturedToken = json.access_token || json.id_token;
            console.log(`🔑 Token captured from OAuth response!`);
          }
        }
      } catch {}
    });

    // Step 1: Wipe session
    console.log('  [1/8] Destroying previous SSO session...');
    await page.goto('https://login.stableaudio.com/v2/logout', {
      waitUntil: 'domcontentloaded',
      timeout: 15000
    }).catch(() => {});
    await sleep(1500);

    // Step 2: Clear storage
    console.log('  [2/8] Clearing context cookies & local storage...');
    await context.clearCookies();
    await page.evaluate(() => {
      try {
        localStorage.clear();
        sessionStorage.clear();
      } catch {}
    }).catch(() => {});

    // Step 3: Navigate to homepage
    console.log('  [3/8] Loading Stable Audio portal...');
    await page.goto('https://stableaudio.com', { waitUntil: 'networkidle', timeout: 35000 });
    await sleep(2000);

    // Step 4: Click Sign Up
    console.log('  [4/8] Triggering registration form...');
    const signupSelectors = [
      'button:has-text("Sign up")',
      'button:has-text("Sign Up")',
      'a:has-text("Sign up")',
      '[data-testid="signup"]'
    ];
    let clicked = false;
    for (const sel of signupSelectors) {
      try {
        await page.waitForSelector(sel, { timeout: 5000 });
        await page.click(sel);
        clicked = true;
        break;
      } catch {}
    }
    if (!clicked) {
      clicked = await page.evaluate(() => {
        const btn = Array.from(document.querySelectorAll('button')).find((b) =>
          ['sign up', 'sign-up'].includes(b.textContent.trim().toLowerCase())
        );
        if (btn) {
          btn.click();
          return true;
        }
        return false;
      });
      if (!clicked) throw new Error('Could not click Sign Up button on target page.');
    }
    await sleep(2500);

    // Step 5: Fill Credentials
    console.log('  [5/8] Injecting identity credentials...');
    await page.waitForSelector('input[name="email"]', { timeout: 20000 });
    await page.evaluate(
      ({ em, pw }) => {
        const setter = Object.getOwnPropertyDescriptor(
          window.HTMLInputElement.prototype,
          'value'
        ).set;
        const emailEl = document.querySelector('input[name="email"]');
        const passEl = document.querySelector('input[name="password"]');
        if (emailEl) {
          setter.call(emailEl, em);
          emailEl.dispatchEvent(new Event('input', { bubbles: true }));
          emailEl.dispatchEvent(new Event('change', { bubbles: true }));
        }
        if (passEl) {
          setter.call(passEl, pw);
          passEl.dispatchEvent(new Event('input', { bubbles: true }));
          passEl.dispatchEvent(new Event('change', { bubbles: true }));
        }
      },
      { em: email, pw: password }
    );
    await sleep(800);

    // Step 6: Submit Form
    console.log('  [6/8] Submitting Auth0 form...');
    await page.waitForSelector('button[type="submit"]', { timeout: 10000 });
    await page.click('button[type="submit"]');

    // Step 7: Wait for OAuth Exchange
    console.log('  [7/8] Exchanging OAuth security tokens...');
    if (!page.url().includes('stableaudio.com')) {
      await page.waitForURL((url) => url.includes('stableaudio.com'), { timeout: 60000 }).catch(() => {});
    }

    if (page.url().includes('code=')) {
      await page.waitForURL((url) => url.includes('stableaudio.com') && !url.includes('code='), {
        timeout: 30000
      }).catch(() => {});
    }
    await sleep(3000);

    // Step 8: Polling Token Extraction
    console.log('  [8/8] Polling for session token...');
    const deadline = Date.now() + 90000;
    while (!capturedToken && Date.now() < deadline) {
      const lsToken = await page
        .evaluate(() => {
          for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            if (!key) continue;
            try {
              const parsed = JSON.parse(localStorage.getItem(key));
              if (parsed?.body?.access_token) return parsed.body.access_token;
              if (parsed?.access_token) return parsed.access_token;
              if (parsed?.idToken) return parsed.idToken;
            } catch {}
          }
          return null;
        })
        .catch(() => null);

      if (lsToken) {
        capturedToken = lsToken;
        break;
      }

      await sleep(1500);
    }

    if (!capturedToken) {
      throw new Error('Token extraction failed within deadline (90s).');
    }

    console.log('✅ NEW ACCOUNT PROVISIONED SUCCESSFULLY!');
    saveStoredToken(capturedToken);
    return capturedToken;
  } finally {
    await browser.close().catch(() => {});
  }
}

// ─── STABLE AUDIO API GENERATION ──────────────────────────────────────────
async function generateAudioFromPrompt({ prompt, duration = 6, isRetry = false, headless = true }) {
  const seed = Math.floor(Math.random() * 65536) - 32768;
  console.log(`🎵 Contacting Stable Audio API (Prompt: "${prompt}", Length: ${duration}s, Seed: ${seed})...`);

  const res = await fetch(
    'https://api.stableaudio.com/v1alpha/generations/stable-audio-v2-5/text-to-music',
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${currentToken}`
      },
      body: JSON.stringify({
        data: {
          type: 'generations',
          attributes: {
            prompts: [{ text: prompt, weight: 1 }],
            length_seconds: duration,
            seed
          }
        }
      })
    }
  );

  if (!res.ok) {
    const errText = await res.text();
    const errLower = errText.toLowerCase();
    const isQuotaOrLimit =
      res.status === 429 ||
      res.status === 401 ||
      (res.status === 400 &&
        (errLower.includes('limit') ||
          errLower.includes('quota') ||
          errLower.includes('credit') ||
          errLower.includes('rate') ||
          errLower.includes('exceeded') ||
          errLower.includes('unauthorized') ||
          errLower.includes('insufficient')));

    if (isQuotaOrLimit && !isRetry) {
      console.warn('\n⚠️ Token expired or quota hit! Auto-provisioning fresh account...');
      currentToken = await createStableAudioAccount(headless);
      console.log('🔄 Retrying audio generation with new bearer token...');
      return generateAudioFromPrompt({ prompt, duration, isRetry: true, headless });
    }
    throw new Error(`Stable Audio API Error (${res.status}): ${errText.slice(0, 300)}`);
  }

  const data = await res.json();
  const resultUrl = data.data[0].links.result;

  // Poll for audio buffer completion
  const maxAttempts = 60;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    process.stdout.write(`  ⏳ Polling generation task... attempt ${attempt}/${maxAttempts}\r`);
    const pollRes = await fetch(resultUrl, {
      headers: { Authorization: `Bearer ${currentToken}`, Accept: '*/*' }
    });

    if (pollRes.status === 200) {
      process.stdout.write('\n');
      console.log('✅ Audio synthesis complete!');
      const arrayBuffer = await pollRes.arrayBuffer();
      return Buffer.from(arrayBuffer);
    }
    if (pollRes.status === 202) {
      await sleep(3000);
    } else {
      throw new Error(`Polling audio task failed with HTTP ${pollRes.status}`);
    }
  }

  throw new Error('Timeout waiting for audio generation task completion.');
}

// ─── FFmpeg SILENCE REMOVAL & AUDIO POST-PROCESSING ──────────────────────
function processRingtoneAudio({ inputPath, outputPath, trimSilence = true, silenceThresholdDb = -45, normalize = false, fade = true }) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(inputPath)) {
      return reject(new Error(`Input file not found: ${inputPath}`));
    }

    const filters = [];

    // 1. Silence removal (Leading & Trailing silence)
    if (trimSilence) {
      filters.push(
        `silenceremove=start_periods=1:start_duration=0.05:start_threshold=${silenceThresholdDb}dB:stop_periods=-1:stop_duration=0.05:stop_threshold=${silenceThresholdDb}dB`
      );
    }

    // 2. Smooth micro fade in/out to prevent speaker pop
    if (fade) {
      filters.push(`afade=t=in:ss=0:d=0.05`);
    }

    // 3. Audio volume normalization for loud, crisp ringtones
    if (normalize) {
      filters.push(`loudnorm=I=-16:TP=-1.5:LRA=11`);
    }

    const args = ['-y', '-i', inputPath];

    if (filters.length > 0) {
      args.push('-af', filters.join(','));
    }

    args.push(outputPath);

    console.log(`🎛️ Running FFmpeg Audio Processor (Silence Trimming: ${trimSilence}, Threshold: ${silenceThresholdDb}dB)...`);

    execFile(ffmpegPath, args, (err, stdout, stderr) => {
      if (err) {
        return reject(new Error(`FFmpeg processing failed: ${stderr || err.message}`));
      }
      resolve(outputPath);
    });
  });
}

// ─── MAIN CLI / ENTRYPOINT ────────────────────────────────────────────────
export async function generateRingtone(options = {}) {
  const {
    prompt = 'Upbeat catchy modern acoustic marimba ringtone',
    duration = 6,
    output = `ringtone_${Date.now()}.mp3`,
    trimSilence = true,
    silenceThreshold = -45,
    normalize = false,
    fade = true,
    headless = true,
    token = null
  } = options;

  if (token) {
    currentToken = token;
    saveStoredToken(token);
  }

  if (!currentToken) {
    console.log('🔑 No cached session token found. Initializing account creation...');
    currentToken = await createStableAudioAccount(headless);
  }

  // Temporary raw file path
  const tempRawFile = path.join(process.cwd(), `temp_raw_${Date.now()}.mp3`);
  const finalOutputFile = path.resolve(process.cwd(), output);

  try {
    // Step 1: Generate audio from prompt
    const audioBuffer = await generateAudioFromPrompt({ prompt, duration, headless });
    fs.writeFileSync(tempRawFile, audioBuffer);
    const rawSizeKb = (audioBuffer.length / 1024).toFixed(1);

    // Step 2: Post-process silence removal & polish
    await processRingtoneAudio({
      inputPath: tempRawFile,
      outputPath: finalOutputFile,
      trimSilence,
      silenceThresholdDb: silenceThreshold,
      normalize,
      fade
    });

    const finalSizeKb = (fs.statSync(finalOutputFile).size / 1024).toFixed(1);

    console.log('\n============================================================');
    console.log('🎉 RINGTONE GENERATION & PROCESSING COMPLETE');
    console.log('============================================================');
    console.log(`📁 File Output : ${finalOutputFile}`);
    console.log(`📊 Raw Size   : ${rawSizeKb} KB`);
    console.log(`✂️ Clean Size : ${finalSizeKb} KB (Silence Trimmed)`);
    console.log('============================================================\n');

    return {
      success: true,
      filePath: finalOutputFile,
      rawSizeKb: parseFloat(rawSizeKb),
      finalSizeKb: parseFloat(finalSizeKb),
      prompt,
      duration
    };
  } finally {
    if (fs.existsSync(tempRawFile)) {
      try { fs.unlinkSync(tempRawFile); } catch {}
    }
  }
}

// Support Direct CLI Execution
if (import.meta.url === `file:///${process.argv[1].replace(/\\/g, '/')}` || process.argv[1]?.endsWith('ringtone_generator.js')) {
  const parseArgs = () => {
    const args = process.argv.slice(2);
    const result = {};
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--prompt' || args[i] === '-p') result.prompt = args[++i];
      else if (args[i] === '--duration' || args[i] === '-d') result.duration = parseInt(args[++i], 10);
      else if (args[i] === '--output' || args[i] === '-o') result.output = args[++i];
      else if (args[i] === '--trim-silence') result.trimSilence = args[++i] !== 'false';
      else if (args[i] === '--silence-threshold') result.silenceThreshold = parseInt(args[++i], 10);
      else if (args[i] === '--normalize') result.normalize = true;
      else if (args[i] === '--headful') result.headless = false;
      else if (args[i] === '--token') result.token = args[++i];
      else if (args[i] === '--help' || args[i] === '-h') {
        console.log(`
Stable Audio Ringtone Generator CLI
Usage: node ringtone_generator.js [options]

Options:
  -p, --prompt <text>         Text prompt describing ringtone sound (default: acoustic marimba ringtone)
  -d, --duration <seconds>    Length in seconds (default: 6)
  -o, --output <filename>     Output mp3 filename (default: ringtone_<timestamp>.mp3)
  --trim-silence <true|false> Enable auto silence trimming (default: true)
  --silence-threshold <dB>    Silence threshold in dB (default: -45)
  --normalize                 Apply audio volume loudness normalization
  --headful                   Show browser UI during auto account creation
  --token <bearer_token>      Supply manual bearer token
  -h, --help                  Show CLI help manual
        `);
        process.exit(0);
      }
    }
    return result;
  };

  const cliOptions = parseArgs();
  generateRingtone(cliOptions).catch((err) => {
    console.error(`\n❌ Error: ${err.message}`);
    process.exit(1);
  });
}
