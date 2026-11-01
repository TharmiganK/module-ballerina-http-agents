// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
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

import ballerina/http;
import ballerina/test;

service /maxAgeZero on new http:Listener(cookieMaxAgeZeroTestPort) {

    resource function get login() returns http:Ok {
        return {headers: {"Set-Cookie": "session=abc123; Path=/"}};
    }

    resource function get logout() returns http:Ok {
        return {headers: {"Set-Cookie": "session=; Max-Age=0; Path=/"}};
    }

    resource function get me(http:Request req) returns string {
        string|http:HeaderNotFoundError cookieHeader = req.getHeader("Cookie");
        return cookieHeader is string ? cookieHeader : "<none>";
    }
}

@test:Config {groups: ["repro_27"]}
function testCookieDeletedWithMaxAgeZeroIsRemovedFromStore() returns error? {
    http:Client clientEp = check new (string `http://localhost:${cookieMaxAgeZeroTestPort}`,
        cookieConfig = {enabled: true});

    http:Response _ = check clientEp->get("/maxAgeZero/login");
    string beforeLogout = check clientEp->get("/maxAgeZero/me");
    test:assertEquals(beforeLogout, "session=abc123", msg = "Cookie should be sent after login");

    http:Response _ = check clientEp->get("/maxAgeZero/logout");

    http:CookieStore? cookieStore = clientEp.getCookieStore();
    if cookieStore !is http:CookieStore {
        test:assertFail("Failed to get cookie store");
    }
    test:assertEquals(cookieStore.getCookiesByName("session").length(), 0,
        msg = "Cookie deleted with Max-Age=0 should be removed from the store");

    string afterLogout = check clientEp->get("/maxAgeZero/me");
    test:assertEquals(afterLogout, "<none>", msg = "Deleted cookie should not be sent");
}
