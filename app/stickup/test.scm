(define (fact x)
  (if (= x 0)
      1
      (* x (fact (- x 1)))))

(display (fact 6))

(define (add x)
  (lambda (y)
    (+ x y)))


