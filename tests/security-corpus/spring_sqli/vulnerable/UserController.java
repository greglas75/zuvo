@RestController
public class UserController {
  @Autowired EntityManager em;
  // VULNERABLE: @RequestParam concatenated into JPQL → SQL injection.
  @GetMapping("/users")
  public List find(@RequestParam String name) {
    return em.createQuery("SELECT u FROM User u WHERE u.name = '" + name + "'").getResultList();
  }
}
