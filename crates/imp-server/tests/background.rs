//! Timers and jobs run in the background and report back on the editor's
//! thread.

mod common;

use common::*;
use std::time::Duration;

fn pump(s: &mut imp_server::Server) {
    s.pump(Duration::from_millis(300));
}

#[test]
fn run_after_fires_once() {
    let mut s = server("");
    s.eval("(define fired 0) (run-after! 20 (lambda () (set! fired (+ fired 1))))")
        .unwrap();
    assert_eq!(s.eval("fired").unwrap(), "0");
    pump(&mut s);
    assert_eq!(s.eval("fired").unwrap(), "1");
}

#[test]
fn run_every_repeats_until_cancelled() {
    let mut s = server("");
    s.eval(
        r#"(define ticks 0)
           (define t #f)
           (set! t (run-every! 10 (lambda ()
                                    (set! ticks (+ ticks 1))
                                    (when (= ticks 3) (cancel-timer! t)))))"#,
    )
    .unwrap();
    pump(&mut s);
    assert_eq!(s.eval("ticks").unwrap(), "3");
}

#[test]
fn jobs_stream_output_and_report_exit() {
    let mut s = server("");
    s.eval(
        r#"(define out "")
           (define code #f)
           (start-job! "cat; echo oops >&2; exit 3" "hello\n"
             (lambda (text stream) (when (equal? stream "stdout") (set! out (string-append out text))))
             (lambda (c) (set! code c)))"#,
    )
    .unwrap();
    pump(&mut s);
    assert_eq!(s.eval("out").unwrap(), "\"hello\\n\"");
    assert_eq!(s.eval("code").unwrap(), "3");
}

#[test]
fn talking_to_a_running_job() {
    let mut s = server("");
    s.eval(
        r#"(define got "")
           (define j (start-job! "cat" #f (lambda (text stream) (set! got (string-append got text))) #f))
           (job-send! j "ping\n")"#,
    )
    .unwrap();
    pump(&mut s);
    assert_eq!(s.eval("got").unwrap(), "\"ping\\n\"");
    s.eval("(job-close-input! j)").unwrap();
    pump(&mut s);
}

#[test]
fn errors_in_callbacks_are_shown() {
    let mut s = server("");
    s.eval("(run-after! 5 (lambda () (car 1)))").unwrap();
    pump(&mut s);
    assert!(s.status().contains("error in timer"), "{}", s.status());
}

#[test]
fn a_socket_that_cannot_connect_says_why() {
    let mut s = server("");
    let path = temp_path("nobody-listens.sock").display().to_string();
    assert_eq!(
        s.eval(&format!("(connect-socket! {path:?} #f #f)"))
            .unwrap(),
        "#false"
    );
    let status = s.status();
    assert!(!status.is_empty() && !status.starts_with('"'), "{status}");
}
