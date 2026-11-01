// Copyright (c) 2021 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// NOTE: All the tokens/credentials used in this test are dummy tokens/credentials and used only for testing purposes.

import ballerina/http;
import ballerina/url;
import ballerina/mime;
import ballerina/test;

final http:Client clientUrlEncodedTestClient = check new(string`http://localhost:${clientFormUrlEncodedTestPort.toString()}/databinding`, httpVersion = http:HTTP_1_1);
final string expectedResponse = "URL_ENCODED_key1=value1&key2=value2";
final readonly & map<string> payload = {
    "key1": "value1",
    "key2": "value2"
};

service /databinding on new http:Listener(clientFormUrlEncodedTestPort, httpVersion = http:HTTP_1_1) {
    resource function 'default .(http:Request req) returns string|error {
        string contentType = req.getContentType();
        contentType = contentType == mime:APPLICATION_FORM_URLENCODED ? "URL_ENCODED": "INVALID";
        string payload = check req.getTextPayload();
        string decodedContent = check url:decode(payload, "UTF-8");
        return string`${contentType}_${decodedContent}`;
    }
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithPost() returns error? {
    string response = check clientUrlEncodedTestClient->post("", payload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentInline() returns error? {
    string response = check clientUrlEncodedTestClient->post("",
    {
        "key1": "value1",
        "key2": "value2"
    }, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithPut() returns error? {
    string response = check clientUrlEncodedTestClient->put("", payload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithDelete() returns error? {
    string response = check clientUrlEncodedTestClient->delete("", payload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithPatch() returns error? {
    string response = check clientUrlEncodedTestClient->patch("", payload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithExecute() returns error? {
    string response = check clientUrlEncodedTestClient->execute("POST", "", payload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertEquals(response, expectedResponse, msg = "Found unexpected output");
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithIntPayload() returns error? {
    string|error response = clientUrlEncodedTestClient->post("", 10, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertTrue(response is error, "Found unexpected output");
    if response is error {
        test:assertEquals(response.message(), "unsupported content for application/x-www-form-urlencoded media type", msg = "Found unexpected output");
    }
}

@test:Config {
    groups: ["urlEncodedContent"]
}
isolated function testUrlContentWithJsonPayload() returns error? {
    json jsonPayload = {
        "key1": "val1",
        "key2": [
            "val2.1", "val2.2"
        ]
    };
    string|error response = clientUrlEncodedTestClient->post("", jsonPayload, mediaType = mime:APPLICATION_FORM_URLENCODED);
    test:assertTrue(response is error, "Found unexpected output");
    if response is error {
        test:assertEquals(response.message(), "unsupported content for application/x-www-form-urlencoded media type", msg = "Found unexpected output");
    }
}

service /formCharset on new http:Listener(formUrlEncodedCharsetBindingPort, httpVersion = http:HTTP_1_1) {
    resource function get token() returns http:Response {
        http:Response res = new;
        res.setPayload("access_token=abc&expires_in=28800&scope=&token_type=bearer",
            mime:APPLICATION_FORM_URLENCODED + "; charset=utf-8");
        return res;
    }

    resource function get upperCaseToken() returns http:Response {
        http:Response res = new;
        res.setPayload("access_token=abc&expires_in=28800&scope=&token_type=bearer",
            "Application/X-WWW-Form-Urlencoded");
        return res;
    }

    resource function get spaceToken() returns http:Response {
        http:Response res = new;
        res.setPayload("access_token=abc&expires_in=28800&scope=&token_type=bearer",
            mime:APPLICATION_FORM_URLENCODED + " ; charset=utf-8");
        return res;
    }

    resource function get jsonPayload() returns http:Response {
        http:Response res = new;
        res.setPayload({name: "abc", age: 10}, "application/json; charset=utf-8");
        return res;
    }

    resource function get textPayload() returns http:Response {
        http:Response res = new;
        res.setPayload("hello", "text/plain; charset=utf-8");
        return res;
    }

    resource function get xmlPayload() returns http:Response {
        http:Response res = new;
        res.setPayload(xml `<name>abc</name>`, "application/xml; charset=utf-8");
        return res;
    }
}

type CharsetPerson record {|
    string name;
    int age;
|};

final http:Client formCharsetClient = check new (string `localhost:${formUrlEncodedCharsetBindingPort}/formCharset`);

@test:Config {
    groups: ["repro_4"]
}
function testFormUrlEncodedResponseWithCharsetBindToMapString() returns error? {
    map<string> res = check formCharsetClient->/token;
    test:assertEquals(res, {"access_token": "abc", "expires_in": "28800", "scope": "", "token_type": "bearer"});
}

@test:Config {
    groups: ["repro_4"]
}
function testFormUrlEncodedResponseWithCharsetBindToNilableMapString() returns error? {
    map<string>? res = check formCharsetClient->/token;
    test:assertEquals(res, {"access_token": "abc", "expires_in": "28800", "scope": "", "token_type": "bearer"});
}

@test:Config {
    groups: ["repro_4"]
}
function testUpperCaseFormUrlEncodedResponseBindToMapString() returns error? {
    map<string> res = check formCharsetClient->/upperCaseToken;
    test:assertEquals(res, {"access_token": "abc", "expires_in": "28800", "scope": "", "token_type": "bearer"});
}

@test:Config {
    groups: ["repro_4"]
}
function testJsonResponseWithCharsetBindToRecord() returns error? {
    CharsetPerson res = check formCharsetClient->/jsonPayload;
    test:assertEquals(res, {name: "abc", age: 10});
}

@test:Config {
    groups: ["repro_4"]
}
function testTextResponseWithCharsetBindToString() returns error? {
    string res = check formCharsetClient->/textPayload;
    test:assertEquals(res, "hello");
}

@test:Config {
    groups: ["repro_4"]
}
function testXmlResponseWithCharsetBindToXml() returns error? {
    xml res = check formCharsetClient->/xmlPayload;
    test:assertEquals(res, xml `<name>abc</name>`);
}

@test:Config {
    groups: ["repro_4"]
}
function testFormUrlEncodedResponseWithSpaceBeforeParamBindToMapString() returns error? {
    map<string> res = check formCharsetClient->/spaceToken;
    test:assertEquals(res, {"access_token": "abc", "expires_in": "28800", "scope": "", "token_type": "bearer"});
}

@test:Config {
    groups: ["repro_4"]
}
function testFormUrlEncodedResponseWithCharsetBindToStatusCodeRecord() returns error? {
    http:StatusCodeClient statusCodeClient = check new (string `localhost:${formUrlEncodedCharsetBindingPort}/formCharset`);
    record {|*http:Ok; map<string> body;|} res = check statusCodeClient->/token;
    test:assertEquals(res.body, {"access_token": "abc", "expires_in": "28800", "scope": "", "token_type": "bearer"});
}

// The media type, not the target type, selects the payload builder even when the content type has
// parameters, so a JSON object payload cannot be bound to `string`.
@test:Config {
    groups: ["repro_4"]
}
function testJsonResponseWithCharsetBindToStringFails() {
    string|error res = formCharsetClient->/jsonPayload;
    test:assertTrue(res is http:PayloadBindingError, "Expected a payload binding error");
}

@test:Config {
    groups: ["repro_4"]
}
function testTextResponseWithCharsetBindToRecordFails() {
    CharsetPerson|error res = formCharsetClient->/textPayload;
    if res is error {
        test:assertTrue(res is http:PayloadBindingError, "Expected a payload binding error");
        test:assertTrue(res.message().startsWith("incompatible typedesc"),
            "Unexpected error message: " + res.message());
    } else {
        test:assertFail("Expected an error, found: " + res.toString());
    }
}
