package main

/* Functions, and void, are not value types. Therefore they cannot be used in
assignments, or be switched on. */

func f() {}

func g() {
  switch ; f { //Error: function type is not a value
    default:
  }
}
