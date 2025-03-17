fn main() {
	s := 'Hello World'.wrap(width: 10)
	s.free()

	s2 := 'Hello World'.wrap(width: 10, end: '<linea-break>')
	s2.free()

	s3 := 'The V programming language'.wrap(width: 20, end: '|')
	s3.free()

	s4 := 'Hello, my name is Carl and I am a delivery'.wrap(width: 20)
	s4.free()
}
