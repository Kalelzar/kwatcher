// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

//! Pinned JWT test vectors.
//!
//! Generated once with openssl (RSA-2048, PKCS#1 v1.5) and committed;
//! regeneration is never needed — the signatures are stable data.
//! Claims: iss https://idp.test/realms/kw, aud kwatcher(+account),
//! sub user-1234, azp kwatcher, exp year 3000, iat 2001-09-09.

pub const jwks =
    "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"test-rs256\",\"alg\":\"RS256\",\"use\":\"sig\",\"n\":\"y-ujqWbByNbenP6yLOJM9GOw" ++
    "JUVJgpDIXipdsDydI421geAPlAU9Pl_6XhaJgtqYN5qQmeb8-jNEqhsbdqCFMbgxwRFLIcW_5GxJ2fmVnCgPGsj0dYk8OWwn" ++
    "uFSLWdUbScaaho-KduaFJZGpMLlvRbm_4Or90O4vPewsPdFXECHos_p5T6Vdgm9Gl4pqPpRWdYmmbMu5ahPYNRDz-3xVqTfk" ++
    "786M4x0VE0ULhdBf0j-5k8wZXT0OjKydJGq5YdtQNthiCSMVWHn46TimY8BPuE4KmbaPvGzw6yUETL9hxbfE9_g_aGkZLIdK" ++
    "XuiCmLe5yS8fJS4DRel7EEnOhWdkmQ\",\"e\":\"AQAB\"},{\"kty\":\"RSA\",\"kid\":\"test-rs384\",\"alg\":\"RS384\",\"use\":" ++
    "\"sig\",\"n\":\"y-ujqWbByNbenP6yLOJM9GOwJUVJgpDIXipdsDydI421geAPlAU9Pl_6XhaJgtqYN5qQmeb8-jNEqhsbdqCFM" ++
    "bgxwRFLIcW_5GxJ2fmVnCgPGsj0dYk8OWwnuFSLWdUbScaaho-KduaFJZGpMLlvRbm_4Or90O4vPewsPdFXECHos_p5T6Vdg" ++
    "m9Gl4pqPpRWdYmmbMu5ahPYNRDz-3xVqTfk786M4x0VE0ULhdBf0j-5k8wZXT0OjKydJGq5YdtQNthiCSMVWHn46TimY8BPu" ++
    "E4KmbaPvGzw6yUETL9hxbfE9_g_aGkZLIdKXuiCmLe5yS8fJS4DRel7EEnOhWdkmQ\",\"e\":\"AQAB\"},{\"kty\":\"RSA\",\"kid" ++
    "\":\"test-rs512\",\"alg\":\"RS512\",\"use\":\"sig\",\"n\":\"y-ujqWbByNbenP6yLOJM9GOwJUVJgpDIXipdsDydI421geAPlA" ++
    "U9Pl_6XhaJgtqYN5qQmeb8-jNEqhsbdqCFMbgxwRFLIcW_5GxJ2fmVnCgPGsj0dYk8OWwnuFSLWdUbScaaho-KduaFJZGpML" ++
    "lvRbm_4Or90O4vPewsPdFXECHos_p5T6Vdgm9Gl4pqPpRWdYmmbMu5ahPYNRDz-3xVqTfk786M4x0VE0ULhdBf0j-5k8wZXT" ++
    "0OjKydJGq5YdtQNthiCSMVWHn46TimY8BPuE4KmbaPvGzw6yUETL9hxbfE9_g_aGkZLIdKXuiCmLe5yS8fJS4DRel7EEnOhW" ++
    "dkmQ\",\"e\":\"AQAB\"}]}";

pub const rs256 =
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnMyNTYifQ.eyJleHAiOjMyNTAzNjgwMDAwLCJpYXQiO" ++
    "jEwMDAwMDAwMDAsImlzcyI6Imh0dHBzOi8vaWRwLnRlc3QvcmVhbG1zL2t3IiwianRpIjoiOGIxZi4uLngiLCJhdWQiOlsia" ++
    "3dhdGNoZXIiLCJhY2NvdW50Il0sInN1YiI6InVzZXItMTIzNCIsImF6cCI6Imt3YXRjaGVyIiwicHJlZmVycmVkX3VzZXJuY" ++
    "W1lIjoia2FsZWx6YXIiLCJlbWFpbCI6ImtAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiY3VzdG9tX2NsY" ++
    "WltIjoiY3VzdG9tLXZhbHVlIn0.rS5we0i1U6kWXGpJ2IqYRpN61yYTcV-18laxcvYmMUqdNo0xPjJlSTPBJEpixU2574vVG" ++
    "W6nrAtewwSlll4bL7GbQ3_ihBQ7z_VhfhJXdcdiaufWg64gZpk8MeRBcAQAIRFRmUd1K3cVyWghD8-LHcw0FOjUPS3FVX-99" ++
    "b74ruuWKqlYxFFVn4VXqqvppmV8jaZwTMW9BnmvD3Zk85ul7pw9nLHy3xtwcoVfYmun-kx_8d467Si8FOxTuDeL1gBT2BpY6" ++
    "ufvayDrKtcDVJSsH3MrU0NRHN-K4tu9MFlm4gJCR_7E53gAu9eP6jcLh-UJ1ojUbInfKhBKurfsCTsjsQ";

pub const rs384 =
    "eyJhbGciOiJSUzM4NCIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnMzODQifQ.eyJleHAiOjMyNTAzNjgwMDAwLCJpYXQiO" ++
    "jEwMDAwMDAwMDAsImlzcyI6Imh0dHBzOi8vaWRwLnRlc3QvcmVhbG1zL2t3IiwianRpIjoiOGIxZi4uLngiLCJhdWQiOiJrd" ++
    "2F0Y2hlciIsInN1YiI6InVzZXItMTIzNCIsImF6cCI6Imt3YXRjaGVyIiwicHJlZmVycmVkX3VzZXJuYW1lIjoia2FsZWx6Y" ++
    "XIiLCJlbWFpbCI6ImtAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiY3VzdG9tX2NsYWltIjoiY3VzdG9tL" ++
    "XZhbHVlIn0.WuntXFz80u_itoVqYCvfFCFlcUJAj2kDWhqzetJls0hw_6UwR4KwzxKBHGjws14yg1JqQgYq-t3eWKT991w0S" ++
    "2QEs89FFnqRoiVKep2c9ukzLHe-CvBh8ejh-M987wfhBug_beMTjQbTQwB0Jl63GWE1hRCVuu9GeMXQbeimatUlhhKjKVTqn" ++
    "Hao-YAstM8Hk42ZM9379dBH-Z-pce2Ce2E6n4-mbd0uUMxi2UqsdwWfmaarte5wbidjIrV39YBldjR9S_YI2_AbQfDo6AvK_" ++
    "9PC7JJwF5WD9NMTisNkBmYaYLUSIizwMpfTKwPuBIFdEU5Ph_ouqACA-hJWsZEXrg";

pub const rs512 =
    "eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnM1MTIifQ.eyJleHAiOjMyNTAzNjgwMDAwLCJpYXQiO" ++
    "jEwMDAwMDAwMDAsImlzcyI6Imh0dHBzOi8vaWRwLnRlc3QvcmVhbG1zL2t3IiwianRpIjoiOGIxZi4uLngiLCJhdWQiOlsia" ++
    "3dhdGNoZXIiLCJhY2NvdW50Il0sInN1YiI6InVzZXItMTIzNCIsImF6cCI6Imt3YXRjaGVyIiwicHJlZmVycmVkX3VzZXJuY" ++
    "W1lIjoia2FsZWx6YXIiLCJlbWFpbCI6ImtAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiY3VzdG9tX2NsY" ++
    "WltIjoiY3VzdG9tLXZhbHVlIn0.VT3IxO3CCd4WPIXrzcpVIusSzOa1UUYFI0FrJwHze8E54Ck1I1U80O3EkQUlPcM1CqWev" ++
    "fZZDMOg_bFdBs0PuGzB2up-jNc3Ca_L9-r5wOqQbE3j-Gh2JYd1kKc26BsDaIOYky7ZdznxPNOqumuIWlNUWiSlAwg2zmbKM" ++
    "2ifd4XS3dXkOGhDyYWHWArIZsa-52bomh0ZWP7eUt99ftT2Bz3heyvmUukySpLv_yh0KryakWNIfxU1pT60yVnw-YJ6E71hx" ++
    "w4wTVocmM-WMhMRSkvseM6EIt8gBgVZPyvMN4wKP4UiNJjjKa873cV4ArbwzFYsIOKDGBqdXax__-BpXA";

pub const unknown_kid =
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtdW5rbm93biJ9.eyJleHAiOjMyNTAzNjgwMDAwLCJpYXQ" ++
    "iOjEwMDAwMDAwMDAsImlzcyI6Imh0dHBzOi8vaWRwLnRlc3QvcmVhbG1zL2t3IiwianRpIjoiOGIxZi4uLngiLCJhdWQiOls" ++
    "ia3dhdGNoZXIiLCJhY2NvdW50Il0sInN1YiI6InVzZXItMTIzNCIsImF6cCI6Imt3YXRjaGVyIiwicHJlZmVycmVkX3VzZXJ" ++
    "uYW1lIjoia2FsZWx6YXIiLCJlbWFpbCI6ImtAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiY3VzdG9tX2N" ++
    "sYWltIjoiY3VzdG9tLXZhbHVlIn0.omdTH7YgCjgGcHTGTPVecvHXxYEFWAcfAj-yxwk99FAkieTz_DKrl7raFKHZfEi6hXG" ++
    "JnLrKdDAVVrdNiiHycGEwwG_GrEveslkWYI9BKuH8LfmnM0vY-VwTVFri2C4LuXR0B3eYeJ0O1oyhitARpPMxIMhuz_v8BrE" ++
    "IhE_EwvpKa0GL9A8kUgfkp_PiW51mtbIKqq3WJYvPwpS9NEMG00ZsnTrePeK5Q9lPIFyFl6KzlbXnQhml43Cf5SCHa1Tz8gm" ++
    "iETg7T6KvFpGBUMa8abZOfav7uNnXeagUgPd6S4edvAhb4x38BvUBH09NOgIg21GAk4pP2Qn8Yh8QKMBWwQ";

pub const alg_mismatch =
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnMzODQifQ.eyJleHAiOjMyNTAzNjgwMDAwLCJpYXQiO" ++
    "jEwMDAwMDAwMDAsImlzcyI6Imh0dHBzOi8vaWRwLnRlc3QvcmVhbG1zL2t3IiwianRpIjoiOGIxZi4uLngiLCJhdWQiOlsia" ++
    "3dhdGNoZXIiLCJhY2NvdW50Il0sInN1YiI6InVzZXItMTIzNCIsImF6cCI6Imt3YXRjaGVyIiwicHJlZmVycmVkX3VzZXJuY" ++
    "W1lIjoia2FsZWx6YXIiLCJlbWFpbCI6ImtAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiY3VzdG9tX2NsY" ++
    "WltIjoiY3VzdG9tLXZhbHVlIn0.cFLGANJ8CKUbu46LfZ5EclalLhWeXFQ7PcbCcKCYqZg5r1jCq-267geIBfKj4aYyVCJ47" ++
    "Bcg5OJ7iz0U_NHE8L-sjurUuLGXg5BcUr4DGA1fH3P_pN5UMfE7qVK792PNWhc88oC4HFtFVexhaHmWpjiyAMJaQayYLJYMm" ++
    "IA4Z3UkWpMQFSZfahDe9XuzpbSM44CqFbxKV8yCUQ6XC1J8xVAneUF2v6aL-pYUD8yY9WmGPmPqVTxNqVfuTpzvfTEp4Q7Oq" ++
    "7cjBC4ufklu28qeockh6LpdOkkYm-lqLnUSA6Avxso51O8LirU2uTUPrGZkSPwqTF6Z3pTHBCV96b_t9Q";
