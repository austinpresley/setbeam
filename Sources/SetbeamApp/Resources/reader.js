"use strict";

/**
 * @callback OnError
 * @param {string} err - error.
 */

/**
 * @callback OnTrack
 * @param {RTCTrackEvent} evt - track event.
 */

/**
 * @callback OnDataChannel
 * @param {RTCDataChannelEvent} evt - data channel event.
 */

/**
 * @typedef Conf
 * @type {object}
 * @property {string} url - absolute URL of the WHEP endpoint.
 * @property {string} user - username.
 * @property {string} pass - password.
 * @property {string} token - token.
 * @property {OnError} onError - called when there's an error.
 * @property {OnTrack} onTrack - called when there's a track available.
 * @property {OnDataChannel} onDataChannel - called when there's a data channel available.
 */

/** WebRTC/WHEP reader. */
class MediaMTXWebRTCReader {
  static #RETRY_PAUSE = 2000;

  #conf;
  #state = "getting_codecs";
  #restartTimeout = null;
  #attempt = null;
  #codecProbe = new AbortController();
  #nonAdvertisedCodecs;

  /**
   * Create a MediaMTXWebRTCReader.
   * @param {Conf} conf - configuration.
   */
  constructor(conf) {
    this.#conf = conf;
    this.#getNonAdvertisedCodecs();
  }

  /**
   * Close the reader and all its resources.
   */
  close() {
    this.#state = "closed";

    this.#codecProbe.abort();
    clearTimeout(this.#restartTimeout);
    this.#stopAttempt();
  }

  // Diagnostics read the existing peer.
  getStats() {
    return this.#attempt?.pc?.getStats() ?? Promise.resolve(new Map());
  }

  static #supportsNonAdvertisedCodec(codec, fmtp, signal) {
    return new Promise((resolve) => {
      const pc = new RTCPeerConnection({ iceServers: [] });
      const mediaType = "audio";
      let payloadType = "", done = false;
      const finish = (supported) => {
        if (done) return;
        done = true;
        clearTimeout(deadline);
        signal.removeEventListener("abort", cancel);
        pc.close();
        resolve(supported);
      };
      const cancel = () => finish(false);
      const deadline = setTimeout(cancel, 5000);
      signal.addEventListener("abort", cancel, {once: true});

      Promise.resolve().then(() => {
        if (signal.aborted) throw new Error("closed");
        pc.addTransceiver(mediaType, { direction: "recvonly" });
        return pc.createOffer();
      })
        .then((offer) => {
          if (done) throw new Error("closed");
          if (offer.sdp === undefined) {
            throw new Error("SDP not present");
          }
          if (offer.sdp.includes(` ${codec}`)) {
            // codec is advertised, there's no need to add it manually
            throw new Error("already present");
          }

          const sections = offer.sdp.split(`m=${mediaType}`);

          const payloadTypes = sections
            .slice(1)
            .map((s) => s.split("\r\n")[0].split(" ").slice(3))
            .reduce((prev, cur) => [...prev, ...cur], []);
          payloadType = this.#reservePayloadType(payloadTypes);

          const lines = sections[1].split("\r\n");
          lines[0] += ` ${payloadType}`;
          lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} ${codec}`);
          if (fmtp !== undefined) {
            lines.splice(lines.length - 1, 0, `a=fmtp:${payloadType} ${fmtp}`);
          }
          sections[1] = lines.join("\r\n");
          offer.sdp = sections.join(`m=${mediaType}`);
          return pc.setLocalDescription(offer);
        })
        .then(() =>
          pc.setRemoteDescription(
            new RTCSessionDescription({
              type: "answer",
              sdp:
                "v=0\r\n" +
                "o=- 6539324223450680508 0 IN IP4 0.0.0.0\r\n" +
                "s=-\r\n" +
                "t=0 0\r\n" +
                "a=fingerprint:sha-256 0D:9F:78:15:42:B5:4B:E6:E2:94:3E:5B:37:78:E1:4B:54:59:A3:36:3A:E5:05:EB:27:EE:8F:D2:2D:41:29:25\r\n" +
                `m=${mediaType} 9 UDP/TLS/RTP/SAVPF ${payloadType}\r\n` +
                "c=IN IP4 0.0.0.0\r\n" +
                "a=ice-pwd:7c3bf4770007e7432ee4ea4d697db675\r\n" +
                "a=ice-ufrag:29e036dc\r\n" +
                "a=sendonly\r\n" +
                "a=rtcp-mux\r\n" +
                `a=rtpmap:${payloadType} ${codec}\r\n` +
                (fmtp !== undefined ? `a=fmtp:${payloadType} ${fmtp}\r\n` : ""),
            }),
          ),
        )
        .then(() => finish(true), cancel);
    });
  }

  static #unquoteCredential(v) {
    return JSON.parse(`"${v}"`);
  }

  static #linkToIceServers(links) {
    return links !== null
      ? links.split(", ").map((link) => {
          const m = link.match(
            /^<(.+?)>; rel="ice-server"(; username="(.*?)"; credential="(.*?)"; credential-type="password")?/i,
          );
          const ret = {
            urls: [m[1]],
          };

          if (m[3] !== undefined) {
            ret.username = this.#unquoteCredential(m[3]);
            ret.credential = this.#unquoteCredential(m[4]);
            ret.credentialType = "password";
          }

          return ret;
        })
      : [];
  }

  static #parseOffer(sdp) {
    const ret = {
      iceUfrag: "",
      icePwd: "",
      medias: [],
    };

    for (const line of sdp.split("\r\n")) {
      if (line.startsWith("m=")) {
        ret.medias.push(line.slice("m=".length));
      } else if (ret.iceUfrag === "" && line.startsWith("a=ice-ufrag:")) {
        ret.iceUfrag = line.slice("a=ice-ufrag:".length);
      } else if (ret.icePwd === "" && line.startsWith("a=ice-pwd:")) {
        ret.icePwd = line.slice("a=ice-pwd:".length);
      }
    }

    return ret;
  }

  static #reservePayloadType(payloadTypes) {
    // everything is valid between 30 and 127, except for interval between 64 and 95
    // https://chromium.googlesource.com/external/webrtc/+/refs/heads/master/call/payload_type.h#29
    for (let i = 30; i <= 127; i++) {
      if ((i <= 63 || i >= 96) && !payloadTypes.includes(i.toString())) {
        const pl = i.toString();
        payloadTypes.push(pl);
        return pl;
      }
    }
    throw Error("unable to find a free payload type");
  }

  static #enableStereoPcmau(payloadTypes, section) {
    const lines = section.split("\r\n");

    let payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} PCMU/8000/2`);
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} PCMA/8000/2`);
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    return lines.join("\r\n");
  }

  static #enableMultichannelOpus(payloadTypes, section) {
    const lines = section.split("\r\n");

    let payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/3`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,2,1;num_streams=2;coupled_streams=1`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/4`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,1,2,3;num_streams=2;coupled_streams=2`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/5`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,4,1,2,3;num_streams=3;coupled_streams=2`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/6`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/7`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,4,1,2,3,5,6;num_streams=4;coupled_streams=4`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(
      lines.length - 1,
      0,
      `a=rtpmap:${payloadType} multiopus/48000/8`,
    );
    lines.splice(
      lines.length - 1,
      0,
      `a=fmtp:${payloadType} channel_mapping=0,6,1,4,5,2,3,7;num_streams=5;coupled_streams=4`,
    );
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    return lines.join("\r\n");
  }

  static #enableL16(payloadTypes, section) {
    const lines = section.split("\r\n");

    let payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} L16/8000/2`);
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} L16/16000/2`);
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    payloadType = this.#reservePayloadType(payloadTypes);
    lines[0] += ` ${payloadType}`;
    lines.splice(lines.length - 1, 0, `a=rtpmap:${payloadType} L16/48000/2`);
    lines.splice(lines.length - 1, 0, `a=rtcp-fb:${payloadType} transport-cc`);

    return lines.join("\r\n");
  }

  static #enableStereoOpus(section) {
    let opusPayloadFormat = "";
    const lines = section.split("\r\n");

    for (let i = 0; i < lines.length; i++) {
      if (
        lines[i].startsWith("a=rtpmap:") &&
        lines[i].toLowerCase().includes("opus/")
      ) {
        opusPayloadFormat = lines[i].slice("a=rtpmap:".length).split(" ")[0];
        break;
      }
    }

    if (opusPayloadFormat === "") {
      return section;
    }

    for (let i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(`a=fmtp:${opusPayloadFormat} `)) {
        if (!lines[i].includes("stereo")) {
          lines[i] += ";stereo=1";
        }
        if (!lines[i].includes("sprop-stereo")) {
          lines[i] += ";sprop-stereo=1";
        }
      }
    }

    return lines.join("\r\n");
  }

  static #editOffer(sdp, nonAdvertisedCodecs) {
    const sections = sdp.split("m=");

    const payloadTypes = sections
      .slice(1)
      .map((s) => s.split("\r\n")[0].split(" ").slice(3))
      .reduce((prev, cur) => [...prev, ...cur], []);

    for (let i = 1; i < sections.length; i++) {
      if (sections[i].startsWith("audio")) {
        sections[i] = this.#enableStereoOpus(sections[i]);

        if (nonAdvertisedCodecs.includes("pcma/8000/2")) {
          sections[i] = this.#enableStereoPcmau(payloadTypes, sections[i]);
        }
        if (nonAdvertisedCodecs.includes("multiopus/48000/6")) {
          sections[i] = this.#enableMultichannelOpus(payloadTypes, sections[i]);
        }
        if (nonAdvertisedCodecs.includes("L16/48000/2")) {
          sections[i] = this.#enableL16(payloadTypes, sections[i]);
        }

        break;
      }
    }

    return sections.join("m=");
  }

  static #generateSdpFragment(od, candidates) {
    const candidatesByMedia = {};
    for (const candidate of candidates) {
      const mid = candidate.sdpMLineIndex;
      if (candidatesByMedia[mid] === undefined) {
        candidatesByMedia[mid] = [];
      }
      candidatesByMedia[mid].push(candidate);
    }

    let frag = `a=ice-ufrag:${od.iceUfrag}\r\n` + `a=ice-pwd:${od.icePwd}\r\n`;

    let mid = 0;

    for (const media of od.medias) {
      if (candidatesByMedia[mid] !== undefined) {
        frag += `m=${media}\r\n` + `a=mid:${mid}\r\n`;

        for (const candidate of candidatesByMedia[mid]) {
          frag += `a=${candidate.candidate}\r\n`;
        }
      }
      mid++;
    }

    return frag;
  }

  #stopAttempt() {
    const attempt = this.#attempt;
    this.#attempt = null;
    if (!attempt) return;
    clearTimeout(attempt.deadline);
    for (const controller of attempt.requests) controller.abort();
    attempt.pc?.close();
    if (attempt.sessionUrl) this.#deleteSession(attempt.sessionUrl);
  }

  #retry(attempt, error) {
    if (this.#attempt !== attempt) return;
    this.#stopAttempt();
    this.#state = "restarting";
    this.#restartTimeout = setTimeout(() => {
      this.#restartTimeout = null;
      if (this.#state !== "restarting") return;
      this.#state = "running";
      this.#start();
    }, MediaMTXWebRTCReader.#RETRY_PAUSE);
    this.#conf.onError?.(`${error}, retrying in some seconds`);
  }

  async #getNonAdvertisedCodecs() {
    try {
      const codecs = await Promise.all([
        ["pcma/8000/2"],
        ["multiopus/48000/6", "channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2"],
        ["L16/48000/2"],
      ].map(async ([codec, fmtp]) =>
        await MediaMTXWebRTCReader.#supportsNonAdvertisedCodec(codec, fmtp, this.#codecProbe.signal) ? codec : false,
      ));
      if (this.#state !== "getting_codecs") return;
      this.#nonAdvertisedCodecs = codecs.filter(Boolean);
      this.#state = "running";
      this.#start();
    } catch (error) {
      if (this.#state !== "getting_codecs") return;
      this.#state = "failed";
      this.#codecProbe.abort();
      this.#conf.onError?.(String(error));
    }
  }

  async #start() {
    const attempt = {requests: new Set(), candidates: []};
    this.#attempt = attempt;
    attempt.deadline = setTimeout(() => this.#retry(attempt, "WHEP negotiation timed out"), 8000);
    try {
      const iceServers = await this.#request(attempt, this.#conf.url, {method: "OPTIONS"}, response => {
        if (!response.ok) throw new Error(`WHEP OPTIONS returned ${response.status}`);
        return MediaMTXWebRTCReader.#linkToIceServers(response.headers.get("Link"));
      });
      if (this.#attempt !== attempt) return;
      const pc = attempt.pc = new RTCPeerConnection({iceServers, sdpSemantics: "unified-plan"});
      pc.addTransceiver("video", {direction: "recvonly"});
      pc.addTransceiver("audio", {direction: "recvonly"});
      pc.createDataChannel("");
      pc.onicecandidate = event => {
        if (this.#attempt !== attempt || !event.candidate) return;
        if (attempt.answered) this.#sendCandidates(attempt, [event.candidate]);
        else attempt.candidates.push(event.candidate);
      };
      pc.onconnectionstatechange = () => {
        if (pc.connectionState === "failed" || pc.connectionState === "closed") this.#retry(attempt, "peer connection closed");
      };
      pc.ontrack = event => { if (this.#attempt === attempt) this.#conf.onTrack?.(event); };
      pc.ondatachannel = event => { if (this.#attempt === attempt) this.#conf.onDataChannel?.(event); };

      const offer = await pc.createOffer();
      if (this.#attempt !== attempt) return;
      offer.sdp = MediaMTXWebRTCReader.#editOffer(offer.sdp, this.#nonAdvertisedCodecs);
      attempt.offerData = MediaMTXWebRTCReader.#parseOffer(offer.sdp);
      await pc.setLocalDescription(offer);
      if (this.#attempt !== attempt) return;
      const answer = await this.#sendOffer(attempt, offer.sdp);
      if (this.#attempt !== attempt) return;
      await pc.setRemoteDescription(new RTCSessionDescription({type: "answer", sdp: answer}));
      if (this.#attempt !== attempt) return;
      clearTimeout(attempt.deadline);
      attempt.answered = true;
      if (attempt.candidates.length) this.#sendCandidates(attempt, attempt.candidates.splice(0));
    } catch (error) { this.#retry(attempt, String(error)); }
  }

  #authHeader() {
    if (this.#conf.user !== undefined && this.#conf.user !== "") {
      const credentials = btoa(`${this.#conf.user}:${this.#conf.pass}`);
      return {Authorization: `Basic ${credentials}`};
    }
    if (this.#conf.token !== undefined && this.#conf.token !== "") {
      return {Authorization: `Bearer ${this.#conf.token}`};
    }
    return {};
  }

  async #request(attempt, url, options, consume = response => response) {
    const controller = new AbortController();
    attempt?.requests.add(controller);
    const deadline = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(url, {...options, signal: controller.signal,
        headers: {...this.#authHeader(), ...options.headers}});
      return await consume(response);
    } finally {
      clearTimeout(deadline);
      attempt?.requests.delete(controller);
    }
  }

  async #sendOffer(attempt, offer) {
    // Closing a local peer cannot cancel an allocation already made by the server.
    // Keep the POST alive briefly so a late Location can still be deleted.
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(this.#conf.url, {
        method: "POST", signal: controller.signal,
        headers: {...this.#authHeader(), "Content-Type": "application/sdp"},
        body: offer,
      });
      if (response.status !== 201) throw new Error(`WHEP POST returned ${response.status}`);
      const location = response.headers.get("Location");
      if (!location) throw new Error("WHEP response has no session location");
      const session = new URL(location, this.#conf.url);
      if (session.origin !== new URL(this.#conf.url).origin) throw new Error("WHEP session origin changed");
      if (this.#attempt !== attempt) {
        this.#deleteSession(session.href);
        controller.abort();
        return;
      }
      attempt.sessionUrl = session.href;
      attempt.requests.add(controller);
      return await response.text();
    } finally {
      clearTimeout(deadline);
      attempt.requests.delete(controller);
    }
  }

  #deleteSession(url) {
    this.#request(null, url, {method: "DELETE", keepalive: true}).catch(() => {});
  }

  async #sendCandidates(attempt, candidates) {
    try {
      const response = await this.#request(attempt, attempt.sessionUrl, {
        method: "PATCH",
        headers: {"Content-Type": "application/trickle-ice-sdpfrag", "If-Match": "*"},
        body: MediaMTXWebRTCReader.#generateSdpFragment(attempt.offerData, candidates),
      });
      if (response.status !== 204) throw new Error(`WHEP PATCH returned ${response.status}`);
    } catch (error) { this.#retry(attempt, String(error)); }
  }
}

window.MediaMTXWebRTCReader = MediaMTXWebRTCReader;
