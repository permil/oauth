# Copyright [2015] [Yoshihiro Tanaka]
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

  # http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Author: Yoshihiro Tanaka <contact@cordea.jp>
# date  :2016-03-03

import times, math, strutils
import hmac, sha1, base64
import httpclient, uri
import subexes
import algorithm
import strtabs

const 
    TEST = false
    signatureMethod = "HMAC-SHA1"
    version = "1.0"

type
    HeaderParams = ref object
        realm, consumerKey, nonce, signature, signatureMethod, timestamp, token, version, callback, verifier: string
    Pair = ref object
        key, value: string

proc initPair(key: string, value: string): Pair =
    result = Pair()
    result.key = key
    result.value = value

proc headerParams2Pairs(params: HeaderParams): seq[Pair] =
    result = @[
        initPair("oauth_consumer_key", params.consumerKey),
        initPair("oauth_nonce", params.nonce),
        initPair("oauth_signature_method", params.signatureMethod),
        initPair("oauth_timestamp", params.timestamp),
        ]
    if params.token != nil:
        result.add initPair("oauth_token", params.token)
    if params.callback != nil:
        result.add initPair("oauth_callback", params.callback)
    if params.version != nil:
        result.add initPair("oauth_version", params.version)
    if params.verifier != nil:
        result.add  initPair("oauth_verifier", params.verifier)

proc httpMethod2String(httpMethod: HttpMethod): string = 
    case httpMethod
    of httpHEAD:
        result = "HEAD"
    of httpGET:
        result = "GET"
    of httpPOST:
        result = "POST"
    of httpPUT:
        result = "PUT"
    of httpDELETE:
        result = "DELETE"
    of httpTRACE:
        result = "TRACE"
    of httpOPTIONS:
        result = "OPTIONS"
    of httpCONNECT:
        result = "CONNECT"

proc percentEncode*(str: string): string =
    result = ""
    for s in str:
        case s
        of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~':
            result = result & s
        else:
            result = result & '%' & toHex(ord s, 2)

proc parameterNormarization(parameters: seq[Pair]): string =
    var
        enParams: seq[Pair] = @[]
        joinParams: seq[string] = @[]

    for p in parameters:
        enParams.add initPair(percentEncode(p.key), percentEncode(p.value))

    enParams.sort do (x, y: Pair) -> int:
        result = cmp(x.key, y.key)
        if result == 0:
            result = cmp(x.value, y.value)

    for p in enParams:
        joinParams.add(p.key & "=" & p.value)

    result = joinParams.join "&"

proc createNonce(): string =
    let epoch = $epochTime()
    var
        rst = ""
        r = 0

    randomize()
    for i in 0..(23 - len(epoch)):
        r = random(26)
        rst = rst & chr(97 + r)

    result = encode(rst & epoch)

proc createSignatureBaseString(httpMethod: HttpMethod, url: string, request: seq[Pair]): string =
    var (url, request) = (url, request)

    let parsed = parseUri(url)
    if parsed.port == "":
        url = subex("$#://$#$#") % [parsed.scheme, parsed.hostname, parsed.path]
    else:
        url = subex("$#://$#:$#$#") % [parsed.scheme, parsed.hostname, parsed.port, parsed.path]
    let queries = parsed.query

    for r in queries.split("&"):
        if r.contains '=':
            var rp = r.split("=")
            request.add(initPair(rp[0], rp[1]))

    let param = parameterNormarization(request)
    result = httpMethod2String(httpMethod) & "&" & percentEncode(url) & "&" & percentEncode(param)

proc createKey(consumerKey: string, token: string): string = 
    result = percentEncode(consumerKey) & "&" & percentEncode(token)

proc createRequestHeader(params: HeaderParams, extraHeaders: string): string =
    result = "Content-Type: application/x-www-form-urlencoded\c\L"
    result = result & extraHeaders
    if len(extraHeaders) > 0 and not extraHeaders.endsWith("\c\L"):
        result = result & "\c\L"
    if params.realm == nil:
        result = result & "Authorization: OAuth "
    else:
        result = result & subex("Authorization: OAuth realm=\"$#\", ") % [ params.realm ]
    result = result & subex("oauth_consumer_key=\"$#\", oauth_signature_method=\"$#\", oauth_timestamp=\"$#\", oauth_nonce=\"$#\", oauth_signature=\"$#\"") % [ params.consumerKey,
    params.signatureMethod,
    params.timestamp,
    params.nonce,
    params.signature]
    if params.token != nil:
        result = result & subex(", oauth_token=\"$#\"") % [ params.token ]
    if params.callback != nil:
        result = result & subex(", oauth_callback=\"$#\"") % [ params.callback ]
    if params.verifier != nil:
        result = result & subex(", oauth_verifier=\"$#\"") % [ params.verifier ]
    if params.version == nil:
        result = result & "\c\L"
    else:
        result = result & subex(", oauth_version=\"$#\"\c\L") % [ params.version ]

proc getOAuth1RequestToken*(url, consumerKey, consumerSecret: string,
    callback = "oob", isIncludeVersionToHeader = false,
    httpMethod = httpPOST, extraHeaders = "", body = "",
    timeout = -1, userAgent = defUserAgent, proxy: Proxy = nil,
    realm: string = nil, nonce: string = nil): Response =
    let
        timestamp = round epochTime()
        nonce = if nonce == nil: createNonce() else: nonce
    var
        body = body
        params = HeaderParams(
            realm: realm,
            consumerKey: consumerKey,
            signatureMethod: signatureMethod,
            timestamp: $timestamp,
            nonce: nonce,
            callback: callback)
    if isIncludeVersionToHeader:
        params.version = version
    let
        signatureBaseString = createSignatureBaseString(httpPOST, url, headerParams2Pairs params)
        signature = hmac_sha1(createKey(consumerSecret, ""), signatureBaseString).toBase64

    params.signature = percentEncode signature
    let header = createRequestHeader(params, extraHeaders)
    result = request(url, httpMethod = httpMethod,
        extraHeaders = header, body = body, timeout = timeout,
        userAgent = userAgent, proxy = proxy)

proc getAuthorizeUrl*(url, requestToken: string): string =
    result = url & "?oauth_token=" & requestToken

proc getOAuth1AccessToken*(url, consumerKey, consumerSecret,
    requestToken, requestTokenSecret, verifier: string,
    isIncludeVersionToHeader = false, httpMethod = httpPOST, extraHeaders = "", body = "",
    timeout = -1, userAgent = defUserAgent, proxy: Proxy = nil,
    nonce: string = nil, realm: string = nil): Response = 
    let
        timestamp = round epochTime()
        nonce = if nonce == nil: createNonce() else: nonce
    var
        params = HeaderParams(
            realm: realm,
            consumerKey: consumerKey,
            signatureMethod: signatureMethod,
            token: requestToken,
            timestamp: $timestamp,
            nonce: nonce,
            verifier: verifier)
    if isIncludeVersionToHeader:
        params.version = version
    let
        signatureBaseString = createSignatureBaseString(httpPOST, url, headerParams2Pairs params)
        signature = hmac_sha1(createKey(consumerSecret, requestTokenSecret), signatureBaseString).toBase64

    params.signature = percentEncode signature
    let header = createRequestHeader(params, extraHeaders)
    result = request(url, httpMethod = httpMethod,
        extraHeaders = header, body = body, timeout = timeout,
        userAgent = userAgent, proxy = proxy)

proc oAuth1Request*(url, consumerKey, consumerSecret, token, tokenSecret: string,
    isIncludeVersionToHeader = false, httpMethod = httpGET, extraHeaders = "", body = "",
    timeout = -1, userAgent = defUserAgent, proxy: Proxy = nil,
    nonce: string = nil, realm: string = nil):Response =

    let
        timestamp = round epochTime()
        nonce = if nonce == nil: createNonce() else: nonce

    var
        params = HeaderParams(
            realm: realm,
            consumerKey: consumerKey,
            nonce: nonce, 
            signatureMethod: signatureMethod,
            timestamp: $timestamp,
            token: token)
    if isIncludeVersionToHeader:
        params.version = version
    let
        signatureBaseString = createSignatureBaseString(httpMethod, url, headerParams2Pairs params)
        signature = hmac_sha1(createKey(consumerSecret, tokenSecret),
                                    signatureBaseString).toBase64

    params.signature = percentEncode(signature)
    let headers = createRequestHeader(params, extraHeaders)
    result = request(url, httpMethod = httpMethod,
        extraHeaders = headers, body = body, timeout = timeout,
        userAgent = userAgent, proxy = proxy)

when isMainModule:
    if TEST:
        # https://dev.twitter.com/oauth/overview/authorizing-requests
        var
            url = "https://api.twitter.com/1/statuses/update.json"
            consumer_secret = "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw"
            token_secret = "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE"
            table = @[
                        initPair("status", "Hello Ladies + Gentlemen, a signed OAuth request!"),
                        initPair("include_entities", "true"),
                        initPair("oauth_consumer_key", "xvz1evFS4wEEPTGEFPHBog"),
                        initPair("oauth_nonce", "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg"),
                        initPair("oauth_signature_method", "HMAC-SHA1"),
                        initPair("oauth_timestamp", "1318622958"),
                        initPair("oauth_token", "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb"),
                        initPair("oauth_version", "1.0")
                    ]
            signature_base_string = createSignatureBaseString(httpPOST, url, table)
            key = createKey(consumer_secret, token_secret)
            oauth_signature = hmac_sha1(key, signature_base_string).toBase64

        doAssert oauth_signature == "tnnArxj06cWHq44gCs1OSKk/jLY="

        # https://tools.ietf.org/html/rfc5849
        url = "http://photos.example.net/photos?file=vacation.jpg&size=original"
        consumer_secret = "kd94hf93k423kf44"
        token_secret = "pfkkdhi9sl3r4s00"
        table = @[
                initPair("oauth_consumer_key", "dpf43f3p2l4k3l03"),
                initPair("oauth_nonce", "chapoH"),
                initPair("oauth_signature_method", "HMAC-SHA1"),
                initPair("oauth_timestamp", "137131202"),
                initPair("oauth_token", "nnch734d00sl2jdk")
            ]
        signature_base_string = createSignatureBaseString(httpGET, url, table)
        key = createKey(consumer_secret, token_secret)
        oauth_signature = hmac_sha1(key, signature_base_string).toBase64

        doAssert percentEncode(oauth_signature) == "MdpQcU8iPSUjWoN%2FUDMsK2sui9I%3D"