fun Route.users() {
  get("/users") {
    val name = call.parameters["name"]          // VULNERABLE: raw concat into SQL
    val rows = transaction { exec("SELECT * FROM users WHERE name = '$name'") }
    call.respond(rows ?: emptyList<Any>())
  }
}
