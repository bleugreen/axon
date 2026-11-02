//! Apple Events, built and sent by the daemon itself.
//!
//! macOS attributes an Apple event to the process that sends it, so the browser verbs send from
//! the daemon through `AESendMessage` rather than through a scripting component: the grant they
//! need is the daemon's, and so is the refusal. A verb asks a browser three kinds of question, each
//! shaped exactly as AppleScript would ask it (measured by intercepting AppleScript's own events):
//! `core/getd` of a property specifier, `core/setd` of one with a `utxt` value, and `core/cnte` of
//! a container with the element class in `kocl`.
//!
//! The request and reply model and [`AppleEventTransport`] are platform-neutral so the verb logic
//! can be exercised with a scripted browser anywhere; [`system`] is the macOS implementation, and
//! the one home of the Apple Event Manager bindings (the consent determination included).

use std::time::Duration;

/// A four-character code, held as the big-endian integer the headers spell with `'pURL'`.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Code(pub u32);

impl Code {
    pub const fn of(code: &[u8; 4]) -> Self {
        Self(u32::from_be_bytes(*code))
    }
}

impl std::fmt::Debug for Code {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "'{}'", String::from_utf8_lossy(&self.0.to_be_bytes()))
    }
}

/// An object specifier: what a question is about.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Spec {
    /// The application itself, the root every specifier hangs from.
    Application,
    /// The `index`th (one-based) element of `class` inside `from`.
    Element {
        class: Code,
        index: i32,
        from: Box<Spec>,
    },
    /// Property `code` of `from`.
    Property { code: Code, from: Box<Spec> },
}

impl Spec {
    pub fn element(class: Code, index: i32, from: Spec) -> Self {
        Self::Element {
            class,
            index,
            from: Box::new(from),
        }
    }
    pub fn property(code: Code, from: Spec) -> Self {
        Self::Property {
            code,
            from: Box::new(from),
        }
    }
}

/// One question for a browser.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum AeQuery {
    /// `get <spec>`.
    Get(Spec),
    /// `set <spec> to <text>`.
    Set(Spec, String),
    /// `count <class> of <container>`.
    Count { container: Spec, class: Code },
}

/// A reply's direct parameter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum AeValue {
    Text(String),
    Int(i64),
    Bool(bool),
    List(Vec<AeValue>),
    /// `missing value`.
    Missing,
    /// The reply carried no direct parameter, which is how a `set` answers.
    Null,
}

/// Why an event did not produce a reply value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum AeError {
    /// `errAEEventNotPermitted`: macOS refused the event itself.
    NotPermitted,
    /// `errAEEventWouldRequireUserConsent`: the event needs a grant nobody has given, and the send
    /// asked not to prompt.
    WouldRequireConsent,
    /// `errAETimeout`: the browser did not answer in time.
    Timeout,
    /// Anything else, with the browser's own error string when the reply carried one.
    Failed {
        status: i32,
        message: Option<String>,
    },
}

pub(crate) const EVENT_NOT_PERMITTED: i32 = -1743;
pub(crate) const WOULD_REQUIRE_CONSENT: i32 = -1744;
pub(crate) const TIMEOUT: i32 = -1712;

impl AeError {
    pub fn from_status(status: i32, message: Option<String>) -> Self {
        match status {
            EVENT_NOT_PERMITTED => Self::NotPermitted,
            WOULD_REQUIRE_CONSENT => Self::WouldRequireConsent,
            TIMEOUT => Self::Timeout,
            _ => Self::Failed { status, message },
        }
    }
}

/// Sends one question to a running application and waits for its answer.
pub(crate) trait AppleEventTransport: Send + Sync {
    /// Never prompts for consent; `timeout` bounds the wait for the reply.
    fn send(
        &self,
        bundle_identifier: &str,
        query: &AeQuery,
        timeout: Duration,
    ) -> Result<AeValue, AeError>;
}

#[cfg(target_os = "macos")]
pub(crate) mod system {
    use super::{AeError, AeQuery, AeValue, AppleEventTransport, Code, Spec};
    use std::{ffi::c_void, time::Duration};

    /// `AEDesc`, which the Apple Event Manager headers pack to two-byte alignment: twelve bytes
    /// with the data handle at offset four on arm64, measured on bgsrv-mac. Only ever handed to
    /// the API by pointer.
    #[repr(C, packed(2))]
    pub(crate) struct AEDesc {
        descriptor_type: u32,
        data_handle: *mut c_void,
    }

    pub(crate) const TYPE_APPLICATION_BUNDLE_ID: Code = Code::of(b"bund");
    pub(crate) const TYPE_WILD_CARD: Code = Code::of(b"****");
    const TYPE_NULL: Code = Code::of(b"null");
    const TYPE_SINT32: Code = Code::of(b"long");
    const TYPE_BOOLEAN: Code = Code::of(b"bool");
    const TYPE_UTF8_TEXT: Code = Code::of(b"utf8");
    const TYPE_UNICODE_TEXT: Code = Code::of(b"utxt");
    const TYPE_TYPE: Code = Code::of(b"type");
    const TYPE_AE_LIST: Code = Code::of(b"list");
    const TYPE_PROPERTY: Code = Code::of(b"prop");
    const FORM_PROPERTY_ID: Code = Code::of(b"prop");
    const FORM_ABSOLUTE_POSITION: Code = Code::of(b"indx");
    const MISSING_VALUE: Code = Code::of(b"msng");
    const CORE_SUITE: Code = Code::of(b"core");
    const GET_DATA: Code = Code::of(b"getd");
    const SET_DATA: Code = Code::of(b"setd");
    const COUNT_ELEMENTS: Code = Code::of(b"cnte");
    const KEY_DIRECT_OBJECT: Code = Code::of(b"----");
    const KEY_DATA: Code = Code::of(b"data");
    const KEY_OBJECT_CLASS: Code = Code::of(b"kocl");
    const KEY_ERROR_NUMBER: Code = Code::of(b"errn");
    const KEY_ERROR_STRING: Code = Code::of(b"errs");

    const AUTO_GENERATE_RETURN_ID: i16 = -1;
    const ANY_TRANSACTION_ID: i32 = 0;
    const WAIT_REPLY: i32 = 0x0000_0003;
    const NEVER_INTERACT: i32 = 0x0000_0010;
    const DONT_RECORD: i32 = 0x0000_1000;
    /// Answer `errAEEventWouldRequireUserConsent` instead of presenting the consent dialog. An
    /// agent's call must never block on a dialog nobody asked for; consent is the menu's gesture.
    const DO_NOT_PROMPT_FOR_USER_CONSENT: i32 = 0x0002_0000;
    const DESC_NOT_FOUND: i16 = -1701;

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn AECreateDesc(
            type_code: u32,
            data: *const c_void,
            size: isize,
            result: *mut AEDesc,
        ) -> i16;
        fn AEDisposeDesc(desc: *mut AEDesc) -> i16;
        fn AEDeterminePermissionToAutomateTarget(
            target: *const AEDesc,
            event_class: u32,
            event_id: u32,
            ask_user_if_needed: u8,
        ) -> i32;
        fn AECreateAppleEvent(
            event_class: u32,
            event_id: u32,
            target: *const AEDesc,
            return_id: i16,
            transaction_id: i32,
            result: *mut AEDesc,
        ) -> i16;
        fn AESendMessage(
            event: *const AEDesc,
            reply: *mut AEDesc,
            send_mode: i32,
            timeout_in_ticks: std::ffi::c_long,
        ) -> i32;
        fn CreateObjSpecifier(
            desired_class: u32,
            container: *mut AEDesc,
            key_form: u32,
            key_data: *mut AEDesc,
            dispose_inputs: u8,
            result: *mut AEDesc,
        ) -> i16;
        fn AEPutParamDesc(event: *mut AEDesc, keyword: u32, desc: *const AEDesc) -> i16;
        fn AEGetParamDesc(
            event: *const AEDesc,
            keyword: u32,
            desired_type: u32,
            result: *mut AEDesc,
        ) -> i16;
        fn AECoerceDesc(desc: *const AEDesc, to_type: u32, result: *mut AEDesc) -> i16;
        fn AECountItems(list: *const AEDesc, count: *mut std::ffi::c_long) -> i16;
        fn AEGetNthDesc(
            list: *const AEDesc,
            index: std::ffi::c_long,
            desired_type: u32,
            keyword: *mut u32,
            result: *mut AEDesc,
        ) -> i16;
        fn AEGetDescDataSize(desc: *const AEDesc) -> isize;
        fn AEGetDescData(desc: *const AEDesc, data: *mut c_void, maximum_size: isize) -> i16;
    }

    /// A descriptor this code owns, disposed when it goes out of scope however a call ends.
    pub(crate) struct OwnedDesc(AEDesc);

    impl OwnedDesc {
        fn null() -> Self {
            Self(AEDesc {
                descriptor_type: 0,
                data_handle: std::ptr::null_mut(),
            })
        }
        fn ptr(&self) -> *const AEDesc {
            &raw const self.0
        }
        fn mut_ptr(&mut self) -> *mut AEDesc {
            &raw mut self.0
        }
        fn descriptor_type(&self) -> Code {
            Code(self.0.descriptor_type)
        }

        fn create(type_code: Code, data: &[u8]) -> Result<Self, AeError> {
            let mut desc = Self::null();
            let status = unsafe {
                AECreateDesc(
                    type_code.0,
                    data.as_ptr().cast(),
                    data.len() as isize,
                    desc.mut_ptr(),
                )
            };
            check(status)?;
            Ok(desc)
        }

        fn coerce(&self, to: Code) -> Result<Self, AeError> {
            let mut desc = Self::null();
            check(unsafe { AECoerceDesc(self.ptr(), to.0, desc.mut_ptr()) })?;
            Ok(desc)
        }

        fn data(&self) -> Vec<u8> {
            let size = unsafe { AEGetDescDataSize(self.ptr()) }.max(0);
            let mut data = vec![0u8; size as usize];
            if size > 0 {
                unsafe { AEGetDescData(self.ptr(), data.as_mut_ptr().cast(), size) };
            }
            data
        }

        fn param(&self, keyword: Code, desired: Code) -> Result<Option<Self>, AeError> {
            let mut desc = Self::null();
            match unsafe { AEGetParamDesc(self.ptr(), keyword.0, desired.0, desc.mut_ptr()) } {
                0 => Ok(Some(desc)),
                DESC_NOT_FOUND => Ok(None),
                status => Err(AeError::from_status(i32::from(status), None)),
            }
        }

        fn put(&mut self, keyword: Code, value: &OwnedDesc) -> Result<(), AeError> {
            check(unsafe { AEPutParamDesc(self.mut_ptr(), keyword.0, value.ptr()) })
        }
    }

    impl Drop for OwnedDesc {
        fn drop(&mut self) {
            unsafe { AEDisposeDesc(self.mut_ptr()) };
        }
    }

    fn check(status: i16) -> Result<(), AeError> {
        if status == 0 {
            Ok(())
        } else {
            Err(AeError::from_status(i32::from(status), None))
        }
    }

    fn target(bundle_identifier: &str) -> Result<OwnedDesc, AeError> {
        OwnedDesc::create(TYPE_APPLICATION_BUNDLE_ID, bundle_identifier.as_bytes())
    }

    /// The specifier as `CreateObjSpecifier` builds it. Inputs are never disposed by the call;
    /// each is owned here and dropped on the way out.
    fn specifier(spec: &Spec) -> Result<OwnedDesc, AeError> {
        let (desired, key_form, key_data, from) = match spec {
            Spec::Application => return OwnedDesc::create(TYPE_NULL, &[]),
            Spec::Element { class, index, from } => (
                *class,
                FORM_ABSOLUTE_POSITION,
                OwnedDesc::create(TYPE_SINT32, &index.to_ne_bytes())?,
                from,
            ),
            Spec::Property { code, from } => (
                TYPE_PROPERTY,
                FORM_PROPERTY_ID,
                OwnedDesc::create(TYPE_TYPE, &code.0.to_ne_bytes())?,
                from,
            ),
        };
        let mut container = specifier(from)?;
        let mut key_data = key_data;
        let mut result = OwnedDesc::null();
        check(unsafe {
            CreateObjSpecifier(
                desired.0,
                container.mut_ptr(),
                key_form.0,
                key_data.mut_ptr(),
                0,
                result.mut_ptr(),
            )
        })?;
        Ok(result)
    }

    /// AppleScript sends `set`'s value as `utxt`, so the text is coerced to it rather than sent as
    /// the `utf8` it starts as.
    fn text(value: &str) -> Result<OwnedDesc, AeError> {
        OwnedDesc::create(TYPE_UTF8_TEXT, value.as_bytes())?.coerce(TYPE_UNICODE_TEXT)
    }

    pub(crate) fn event(target: &OwnedDesc, query: &AeQuery) -> Result<OwnedDesc, AeError> {
        let id = match query {
            AeQuery::Get(_) => GET_DATA,
            AeQuery::Set(..) => SET_DATA,
            AeQuery::Count { .. } => COUNT_ELEMENTS,
        };
        let mut event = OwnedDesc::null();
        check(unsafe {
            AECreateAppleEvent(
                CORE_SUITE.0,
                id.0,
                target.ptr(),
                AUTO_GENERATE_RETURN_ID,
                ANY_TRANSACTION_ID,
                event.mut_ptr(),
            )
        })?;
        match query {
            AeQuery::Get(spec) => event.put(KEY_DIRECT_OBJECT, &specifier(spec)?)?,
            AeQuery::Set(spec, value) => {
                event.put(KEY_DIRECT_OBJECT, &specifier(spec)?)?;
                event.put(KEY_DATA, &text(value)?)?;
            }
            AeQuery::Count { container, class } => {
                event.put(KEY_DIRECT_OBJECT, &specifier(container)?)?;
                event.put(
                    KEY_OBJECT_CLASS,
                    &OwnedDesc::create(TYPE_TYPE, &class.0.to_ne_bytes())?,
                )?;
            }
        }
        Ok(event)
    }

    fn utf8(desc: &OwnedDesc) -> Result<String, AeError> {
        let text = desc.coerce(TYPE_UTF8_TEXT)?;
        Ok(String::from_utf8_lossy(&text.data()).into_owned())
    }

    fn value(desc: &OwnedDesc) -> Result<AeValue, AeError> {
        let kind = desc.descriptor_type();
        if kind == TYPE_NULL {
            return Ok(AeValue::Null);
        }
        if kind == TYPE_TYPE && desc.data() == MISSING_VALUE.0.to_ne_bytes() {
            return Ok(AeValue::Missing);
        }
        if kind == TYPE_AE_LIST {
            let mut count: std::ffi::c_long = 0;
            check(unsafe { AECountItems(desc.ptr(), &raw mut count) })?;
            return (1..=count)
                .map(|index| {
                    let mut item = OwnedDesc::null();
                    check(unsafe {
                        AEGetNthDesc(
                            desc.ptr(),
                            index,
                            TYPE_WILD_CARD.0,
                            std::ptr::null_mut(),
                            item.mut_ptr(),
                        )
                    })?;
                    value(&item)
                })
                .collect::<Result<_, _>>()
                .map(AeValue::List);
        }
        if [Code::of(b"bool"), Code::of(b"true"), Code::of(b"fals")].contains(&kind) {
            let flag = desc.coerce(TYPE_BOOLEAN)?.data();
            return Ok(AeValue::Bool(flag.first().is_some_and(|byte| *byte != 0)));
        }
        if [
            Code::of(b"long"),
            Code::of(b"shor"),
            Code::of(b"comp"),
            Code::of(b"magn"),
        ]
        .contains(&kind)
        {
            let number = desc.coerce(TYPE_SINT32)?.data();
            let bytes: [u8; 4] = number.try_into().map_err(|_| AeError::Failed {
                status: 0,
                message: Some("integer reply of unexpected size".into()),
            })?;
            return Ok(AeValue::Int(i64::from(i32::from_ne_bytes(bytes))));
        }
        utf8(desc).map(AeValue::Text).map_err(|_| AeError::Failed {
            status: 0,
            message: Some(format!("unexpected reply type {kind:?}")),
        })
    }

    /// The browser's error, read from the reply, when it answered with one.
    fn reply_error(reply: &OwnedDesc) -> Option<AeError> {
        let number = reply.param(KEY_ERROR_NUMBER, TYPE_SINT32).ok().flatten()?;
        let bytes: [u8; 4] = number.data().try_into().ok()?;
        let status = i32::from_ne_bytes(bytes);
        if status == 0 {
            return None;
        }
        let message = reply
            .param(KEY_ERROR_STRING, TYPE_UTF8_TEXT)
            .ok()
            .flatten()
            .map(|text| String::from_utf8_lossy(&text.data()).into_owned());
        Some(AeError::from_status(status, message))
    }

    fn ticks(timeout: Duration) -> std::ffi::c_long {
        ((timeout.as_millis() * 60).div_ceil(1_000) as std::ffi::c_long).max(1)
    }

    /// Sends through `AESendMessage`, which is thread-safe and blocks on a Mach port rather than a
    /// run loop, so it is called from the backend worker directly.
    pub(crate) struct SystemTransport;

    impl AppleEventTransport for SystemTransport {
        fn send(
            &self,
            bundle_identifier: &str,
            query: &AeQuery,
            timeout: Duration,
        ) -> Result<AeValue, AeError> {
            let started = std::time::Instant::now();
            let outcome = (|| {
                let event = event(&target(bundle_identifier)?, query)?;
                let mut reply = OwnedDesc::null();
                let status = unsafe {
                    AESendMessage(
                        event.ptr(),
                        reply.mut_ptr(),
                        WAIT_REPLY | NEVER_INTERACT | DONT_RECORD | DO_NOT_PROMPT_FOR_USER_CONSENT,
                        ticks(timeout),
                    )
                };
                if status != 0 {
                    return Err(AeError::from_status(status, None));
                }
                if let Some(error) = reply_error(&reply) {
                    return Err(error);
                }
                match reply.param(KEY_DIRECT_OBJECT, TYPE_WILD_CARD)? {
                    Some(direct) => value(&direct),
                    None => Ok(AeValue::Null),
                }
            })();
            let status = match &outcome {
                Ok(_) => 0,
                Err(AeError::NotPermitted) => super::EVENT_NOT_PERMITTED,
                Err(AeError::WouldRequireConsent) => super::WOULD_REQUIRE_CONSENT,
                Err(AeError::Timeout) => super::TIMEOUT,
                Err(AeError::Failed { status, .. }) => *status,
            };
            eprintln!(
                "axon-mac: apple event target={bundle_identifier} event={} status={status} ms={}",
                match query {
                    AeQuery::Get(_) => "core/getd",
                    AeQuery::Set(..) => "core/setd",
                    AeQuery::Count { .. } => "core/cnte",
                },
                started.elapsed().as_millis()
            );
            outcome
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` for every event of `bundle_identifier`. With `ask`
    /// it may present the consent dialog and blocks until a person answers it.
    pub(crate) fn determine_permission(bundle_identifier: &str, ask: bool) -> i32 {
        let target = match target(bundle_identifier) {
            Ok(target) => target,
            Err(AeError::Failed { status, .. }) => return status,
            Err(_) => return -50,
        };
        unsafe {
            AEDeterminePermissionToAutomateTarget(
                target.ptr(),
                TYPE_WILD_CARD.0,
                TYPE_WILD_CARD.0,
                u8::from(ask),
            )
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::browser::Dictionary;

        #[link(name = "CoreServices", kind = "framework")]
        unsafe extern "C" {
            fn AEPrintDescToHandle(desc: *const AEDesc, result: *mut *mut *mut i8) -> i32;
            fn DisposeHandle(handle: *mut *mut i8);
        }

        fn printed(desc: &OwnedDesc) -> String {
            let mut handle: *mut *mut i8 = std::ptr::null_mut();
            assert_eq!(
                unsafe { AEPrintDescToHandle(desc.ptr(), &raw mut handle) },
                0
            );
            let text = unsafe { std::ffi::CStr::from_ptr(*handle) }
                .to_string_lossy()
                .into_owned();
            unsafe { DisposeHandle(handle) };
            text
        }

        /// The parameters of the event `query` builds, printed by the Apple Event Manager, without
        /// sending anything.
        fn params(query: &AeQuery, keywords: &[Code]) -> Vec<String> {
            let event = event(&target("com.example.never-sent").unwrap(), query).unwrap();
            keywords
                .iter()
                .map(|keyword| printed(&event.param(*keyword, TYPE_WILD_CARD).unwrap().unwrap()))
                .collect()
        }

        fn element(class: &str, index: i32, from: &str) -> String {
            format!("'obj '{{ 'want':'{class}', 'from':{from}, 'form':'indx', 'seld':{index} }}")
        }

        fn property_of(code: &str, from: &str) -> String {
            format!("'obj '{{ 'want':'prop', 'from':{from}, 'form':'prop', 'seld':'{code}' }}")
        }

        /// Every key and value AppleScript's own events carried when intercepted on bgsrv-mac and
        /// local. AppleScript's printout lists a specifier's keys as form, want, seld, from, and
        /// `CreateObjSpecifier`'s as want, from, form, seld; a record is keyed, so the order is not
        /// part of what the browser receives, and these strings use the order this code produces.
        #[test]
        fn events_are_encoded_the_way_applescript_encodes_them() {
            for (dictionary, current, url) in [
                (Dictionary::SAFARI, "cTab", "pURL"),
                (Dictionary::CHROME, "acTa", "URL "),
            ] {
                let tab = property_of(current, &element("cwin", 1, "null()"));
                assert_eq!(
                    params(
                        &AeQuery::Get(dictionary.active_tab_property(1, dictionary.url)),
                        &[KEY_DIRECT_OBJECT]
                    ),
                    [property_of(url, &tab)]
                );
                assert_eq!(
                    params(
                        &AeQuery::Set(
                            dictionary.active_tab_property(1, dictionary.url),
                            "https://example.com/".into()
                        ),
                        &[KEY_DIRECT_OBJECT, KEY_DATA]
                    ),
                    [
                        property_of(url, &tab),
                        "'utxt'(\"https://example.com/\")".to_owned()
                    ]
                );
                assert_eq!(
                    params(
                        &dictionary.count_windows(),
                        &[KEY_DIRECT_OBJECT, KEY_OBJECT_CLASS]
                    ),
                    ["null()".to_owned(), "'cwin'".to_owned()]
                );
            }
            let window_two = &element("cwin", 2, "null()");
            assert_eq!(
                params(
                    &Dictionary::SAFARI.count_tabs(2),
                    &[KEY_DIRECT_OBJECT, KEY_OBJECT_CLASS]
                ),
                [window_two.to_owned(), "'bTab'".to_owned()]
            );
            assert_eq!(
                params(
                    &Dictionary::CHROME.count_tabs(2),
                    &[KEY_DIRECT_OBJECT, KEY_OBJECT_CLASS]
                ),
                [window_two.to_owned(), "'CrTb'".to_owned()]
            );
            assert_eq!(
                params(&Dictionary::SAFARI.active_index(2), &[KEY_DIRECT_OBJECT]),
                [property_of("pidx", &property_of("cTab", window_two))]
            );
            assert_eq!(
                params(&Dictionary::CHROME.active_index(2), &[KEY_DIRECT_OBJECT]),
                [property_of("acTI", window_two)]
            );
            let tab_three = element("bTab", 3, window_two);
            assert_eq!(
                params(
                    &AeQuery::Get(Dictionary::SAFARI.tab_property(2, 3, Dictionary::SAFARI.url)),
                    &[KEY_DIRECT_OBJECT]
                ),
                [property_of("pURL", &tab_three)]
            );
            assert_eq!(
                params(
                    &AeQuery::Get(Dictionary::window_name(2)),
                    &[KEY_DIRECT_OBJECT]
                ),
                [property_of("pnam", window_two)]
            );
        }

        #[test]
        fn replies_decode_text_numbers_flags_lists_and_missing_values() {
            let text = OwnedDesc::create(TYPE_UTF8_TEXT, "Café".as_bytes()).unwrap();
            assert_eq!(value(&text).unwrap(), AeValue::Text("Café".into()));
            let unicode = text.coerce(TYPE_UNICODE_TEXT).unwrap();
            assert_eq!(value(&unicode).unwrap(), AeValue::Text("Café".into()));
            let number = OwnedDesc::create(TYPE_SINT32, &7i32.to_ne_bytes()).unwrap();
            assert_eq!(value(&number).unwrap(), AeValue::Int(7));
            let flag = OwnedDesc::create(TYPE_BOOLEAN, &[1]).unwrap();
            assert_eq!(value(&flag).unwrap(), AeValue::Bool(true));
            let missing = OwnedDesc::create(TYPE_TYPE, &MISSING_VALUE.0.to_ne_bytes()).unwrap();
            assert_eq!(value(&missing).unwrap(), AeValue::Missing);
        }

        #[test]
        fn the_descriptor_layout_and_codes_match_the_headers() {
            assert_eq!(TYPE_APPLICATION_BUNDLE_ID.0, 0x6275_6e64);
            assert_eq!(TYPE_WILD_CARD.0, 0x2a2a_2a2a);
            assert_eq!(std::mem::size_of::<AEDesc>(), 12);
            assert_eq!(ticks(Duration::from_secs(15)), 900);
            assert_eq!(ticks(Duration::from_millis(1)), 1);
        }
    }
}
